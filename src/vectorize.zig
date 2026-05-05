const std = @import("std");
const time_utils = @import("time_utils.zig");

const MAX_AMOUNT: f64 = 10000.0;
const MAX_INSTALLMENTS: f64 = 12.0;
const AMOUNT_VS_AVG_RATIO: f64 = 10.0;
const MAX_MINUTES: f64 = 1440.0;
const MAX_KM: f64 = 1000.0;
const MAX_TX_COUNT_24H: f64 = 20.0;
const MAX_MERCHANT_AVG_AMOUNT: f64 = 10000.0;

pub const Payload = struct {
    amount: f64 = 0,
    installments: f64 = 0,
    requested_at: []const u8 = "",

    avg_amount: f64 = 0,
    tx_count_24h: f64 = 0,
    known_merchants: [32][]const u8 = [_][]const u8{""} ** 32,
    known_merchants_count: u8 = 0,

    merchant_id: []const u8 = "",
    mcc: []const u8 = "",
    merchant_avg_amount: f64 = 0,

    is_online: bool = false,
    card_present: bool = false,
    km_from_home: f64 = 0,

    has_last_tx: bool = false,
    last_tx_timestamp: []const u8 = "",
    km_from_current: f64 = 0,
};

pub fn clamp01(x: f64) f32 {
    if (x < 0.0) return 0.0;
    if (x > 1.0) return 1.0;
    return @floatCast(x);
}

pub fn mccRisk(mcc: []const u8) f32 {
    if (mcc.len != 4) return 0.5;

    const key = mcc[0..4].*;
    if (std.mem.eql(u8, &key, "5411")) return 0.15;
    if (std.mem.eql(u8, &key, "5812")) return 0.30;
    if (std.mem.eql(u8, &key, "5912")) return 0.20;
    if (std.mem.eql(u8, &key, "5944")) return 0.45;
    if (std.mem.eql(u8, &key, "7801")) return 0.80;
    if (std.mem.eql(u8, &key, "7802")) return 0.75;
    if (std.mem.eql(u8, &key, "7995")) return 0.85;
    if (std.mem.eql(u8, &key, "4511")) return 0.35;
    if (std.mem.eql(u8, &key, "5311")) return 0.25;
    if (std.mem.eql(u8, &key, "5999")) return 0.50;
    return 0.5;
}

pub fn isUnknownMerchant(merchant_id: []const u8, known: []const []const u8) bool {
    for (known) |km| {
        if (km.len == merchant_id.len and std.mem.eql(u8, km, merchant_id)) {
            return false;
        }
    }
    return true;
}

pub fn vectorize(p: *const Payload) [16]f32 {
    var vec: [16]f32 = [_]f32{0} ** 16;

    vec[0] = clamp01(p.amount / MAX_AMOUNT);

    vec[1] = clamp01(p.installments / MAX_INSTALLMENTS);

    if (p.avg_amount > 0.0) {
        vec[2] = clamp01((p.amount / p.avg_amount) / AMOUNT_VS_AVG_RATIO);
    } else {
        vec[2] = clamp01(p.amount / AMOUNT_VS_AVG_RATIO);
    }

    if (time_utils.parseTimestamp(p.requested_at)) |ts| {
        vec[3] = @as(f32, @floatFromInt(ts.hour)) / 23.0;

        const dow = time_utils.dayOfWeek(ts.year, ts.month, ts.day);
        vec[4] = @as(f32, @floatFromInt(dow)) / 6.0;

        if (p.has_last_tx) {
            if (time_utils.parseTimestamp(p.last_tx_timestamp)) |last_ts| {
                const mins = time_utils.minutesBetween(ts, last_ts);
                vec[5] = clamp01(mins / MAX_MINUTES);
            } else {
                vec[5] = -1.0;
            }
        } else {
            vec[5] = -1.0;
        }
    } else {
        vec[3] = 0;
        vec[4] = 0;
        vec[5] = if (p.has_last_tx) 0.0 else -1.0;
    }

    if (p.has_last_tx) {
        vec[6] = clamp01(p.km_from_current / MAX_KM);
    } else {
        vec[6] = -1.0;
    }

    vec[7] = clamp01(p.km_from_home / MAX_KM);

    vec[8] = clamp01(p.tx_count_24h / MAX_TX_COUNT_24H);

    vec[9] = if (p.is_online) 1.0 else 0.0;

    vec[10] = if (p.card_present) 1.0 else 0.0;

    const known_slice = p.known_merchants[0..p.known_merchants_count];
    vec[11] = if (isUnknownMerchant(p.merchant_id, known_slice)) 1.0 else 0.0;

    vec[12] = mccRisk(p.mcc);

    vec[13] = clamp01(p.merchant_avg_amount / MAX_MERCHANT_AVG_AMOUNT);

    return vec;
}

pub fn decide(fraud_count: u8) struct { approved: bool, fraud_score: f32 } {
    const score: f32 = @as(f32, @floatFromInt(fraud_count)) / 5.0;
    return .{
        .approved = score < 0.6,
        .fraud_score = score,
    };
}

test "clamp01" {
    try std.testing.expectEqual(@as(f32, 0.0), clamp01(-0.5));
    try std.testing.expectEqual(@as(f32, 0.5), clamp01(0.5));
    try std.testing.expectEqual(@as(f32, 1.0), clamp01(1.5));
    try std.testing.expectEqual(@as(f32, 0.0), clamp01(0.0));
    try std.testing.expectEqual(@as(f32, 1.0), clamp01(1.0));
}

test "mccRisk known codes" {
    try std.testing.expectEqual(@as(f32, 0.15), mccRisk("5411"));
    try std.testing.expectEqual(@as(f32, 0.85), mccRisk("7995"));
    try std.testing.expectEqual(@as(f32, 0.75), mccRisk("7802"));
}

test "mccRisk default" {
    try std.testing.expectEqual(@as(f32, 0.5), mccRisk("9999"));
    try std.testing.expectEqual(@as(f32, 0.5), mccRisk("abc"));
}

test "unknown_merchant found" {
    const known = [_][]const u8{ "MERC-003", "MERC-016" };
    try std.testing.expect(!isUnknownMerchant("MERC-016", &known));
}

test "unknown_merchant not found" {
    const known = [_][]const u8{ "MERC-003", "MERC-016" };
    try std.testing.expect(isUnknownMerchant("MERC-099", &known));
}

test "decide approved" {
    const d = decide(0);
    try std.testing.expect(d.approved);
    try std.testing.expectEqual(@as(f32, 0.0), d.fraud_score);
}

test "decide rejected" {
    const d = decide(5);
    try std.testing.expect(!d.approved);
    try std.testing.expectEqual(@as(f32, 1.0), d.fraud_score);
}

test "decide boundary 3/5 = 0.6 => rejected" {
    const d = decide(3);
    try std.testing.expect(!d.approved);
    try std.testing.expectEqual(@as(f32, 0.6), d.fraud_score);
}

test "decide boundary 2/5 = 0.4 => approved" {
    const d = decide(2);
    try std.testing.expect(d.approved);
    try std.testing.expectApproxEqAbs(@as(f32, 0.4), d.fraud_score, 0.001);
}

test "vectorize legit example from docs" {
    var p = Payload{
        .amount = 41.12,
        .installments = 2,
        .requested_at = "2026-03-11T18:45:53Z",
        .avg_amount = 82.24,
        .tx_count_24h = 3,
        .known_merchants_count = 2,
        .merchant_id = "MERC-016",
        .mcc = "5411",
        .merchant_avg_amount = 60.25,
        .is_online = false,
        .card_present = true,
        .km_from_home = 29.23,
        .has_last_tx = false,
    };
    p.known_merchants[0] = "MERC-003";
    p.known_merchants[1] = "MERC-016";

    const vec = vectorize(&p);
    const eps: f32 = 0.01;

    try std.testing.expectApproxEqAbs(@as(f32, 0.0041), vec[0], eps);
    try std.testing.expectApproxEqAbs(@as(f32, 0.1667), vec[1], eps);
    try std.testing.expectApproxEqAbs(@as(f32, 0.05), vec[2], eps);
    try std.testing.expectApproxEqAbs(@as(f32, 0.7826), vec[3], eps);
    try std.testing.expectApproxEqAbs(@as(f32, 0.3333), vec[4], eps);
    try std.testing.expectApproxEqAbs(@as(f32, -1.0), vec[5], eps);
    try std.testing.expectApproxEqAbs(@as(f32, -1.0), vec[6], eps);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0292), vec[7], eps);
    try std.testing.expectApproxEqAbs(@as(f32, 0.15), vec[8], eps);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), vec[9], eps);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), vec[10], eps);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), vec[11], eps);
    try std.testing.expectApproxEqAbs(@as(f32, 0.15), vec[12], eps);
    try std.testing.expectApproxEqAbs(@as(f32, 0.006), vec[13], eps);
}
