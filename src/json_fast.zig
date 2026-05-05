const std = @import("std");
const vectorize = @import("vectorize.zig");

const Payload = vectorize.Payload;
const Scope = enum {
    root,
    transaction,
    customer,
    merchant,
    terminal,
    last_transaction,
};

pub fn parse(json: []const u8) ?Payload {
    var p = Payload{};
    var i: usize = 0;
    var scope: Scope = .root;

    while (i < json.len) {
        if (json[i] == '"') {
            const key_end = findChar(json, i + 1, '"') orelse break;
            const key = json[i + 1 .. key_end];
            i = key_end + 1;

            i = skipWhitespace(json, i);
            if (i >= json.len or json[i] != ':') {
                i += 1;
                continue;
            }
            i += 1;
            i = skipWhitespace(json, i);

            if (i < json.len and json[i] == '{') {
                scope = if (std.mem.eql(u8, key, "transaction"))
                    .transaction
                else if (std.mem.eql(u8, key, "customer"))
                    .customer
                else if (std.mem.eql(u8, key, "merchant"))
                    .merchant
                else if (std.mem.eql(u8, key, "terminal"))
                    .terminal
                else if (std.mem.eql(u8, key, "last_transaction")) blk: {
                    p.has_last_tx = true;
                    break :blk .last_transaction;
                } else scope;
                i += 1;
                continue;
            }

            if (std.mem.eql(u8, key, "last_transaction") and i < json.len and json[i] == 'n') {
                scope = .root;
                p.has_last_tx = false;
                i += 4;
                continue;
            }

            switch (scope) {
                .transaction => {
                    if (std.mem.eql(u8, key, "amount")) {
                        if (extractNumber(json, i)) |n| {
                            p.amount = n.val;
                            i = n.end;
                        }
                    } else if (std.mem.eql(u8, key, "installments")) {
                        if (extractNumber(json, i)) |n| {
                            p.installments = n.val;
                            i = n.end;
                        }
                    } else if (std.mem.eql(u8, key, "requested_at")) {
                        if (extractString(json, i)) |s| {
                            p.requested_at = s.val;
                            i = s.end;
                        }
                    }
                },
                .customer => {
                    if (std.mem.eql(u8, key, "avg_amount")) {
                        if (extractNumber(json, i)) |n| {
                            p.avg_amount = n.val;
                            i = n.end;
                        }
                    } else if (std.mem.eql(u8, key, "tx_count_24h")) {
                        if (extractNumber(json, i)) |n| {
                            p.tx_count_24h = n.val;
                            i = n.end;
                        }
                    } else if (std.mem.eql(u8, key, "known_merchants")) {
                        i = parseStringArray(json, i, &p.known_merchants, &p.known_merchants_count);
                    }
                },
                .merchant => {
                    if (std.mem.eql(u8, key, "id")) {
                        if (extractString(json, i)) |s| {
                            p.merchant_id = s.val;
                            i = s.end;
                        }
                    } else if (std.mem.eql(u8, key, "mcc")) {
                        if (extractString(json, i)) |s| {
                            p.mcc = s.val;
                            i = s.end;
                        }
                    } else if (std.mem.eql(u8, key, "avg_amount")) {
                        if (extractNumber(json, i)) |n| {
                            p.merchant_avg_amount = n.val;
                            i = n.end;
                        }
                    }
                },
                .terminal => {
                    if (std.mem.eql(u8, key, "is_online")) {
                        if (extractBool(json, i)) |b| {
                            p.is_online = b.val;
                            i = b.end;
                        }
                    } else if (std.mem.eql(u8, key, "card_present")) {
                        if (extractBool(json, i)) |b| {
                            p.card_present = b.val;
                            i = b.end;
                        }
                    } else if (std.mem.eql(u8, key, "km_from_home")) {
                        if (extractNumber(json, i)) |n| {
                            p.km_from_home = n.val;
                            i = n.end;
                        }
                    }
                },
                .last_transaction => {
                    if (std.mem.eql(u8, key, "timestamp")) {
                        if (extractString(json, i)) |s| {
                            p.last_tx_timestamp = s.val;
                            i = s.end;
                        }
                    } else if (std.mem.eql(u8, key, "km_from_current")) {
                        if (extractNumber(json, i)) |n| {
                            p.km_from_current = n.val;
                            i = n.end;
                        }
                    }
                },
                .root => {},
            }
        } else if (json[i] == '}' and scope != .root) {
            scope = .root;
            i += 1;
        } else {
            i += 1;
        }
    }

    return p;
}

const NumberResult = struct { val: f64, end: usize };
const StringResult = struct { val: []const u8, end: usize };
const BoolResult = struct { val: bool, end: usize };

fn parseSimpleNumber(num: []const u8) ?f64 {
    if (num.len == 0) return null;

    var i: usize = 0;
    var negative = false;
    if (num[i] == '-') {
        negative = true;
        i += 1;
    } else if (num[i] == '+') {
        i += 1;
    }

    if (i >= num.len) return null;

    var value: f64 = 0.0;
    var saw_digit = false;
    while (i < num.len and num[i] >= '0' and num[i] <= '9') : (i += 1) {
        saw_digit = true;
        value = value * 10.0 + @as(f64, @floatFromInt(num[i] - '0'));
    }

    if (i < num.len and num[i] == '.') {
        i += 1;
        var scale: f64 = 0.1;
        while (i < num.len and num[i] >= '0' and num[i] <= '9') : (i += 1) {
            saw_digit = true;
            value += @as(f64, @floatFromInt(num[i] - '0')) * scale;
            scale *= 0.1;
        }
    }

    if (!saw_digit or i != num.len) return null;
    return if (negative) -value else value;
}

fn extractNumber(json: []const u8, start: usize) ?NumberResult {
    var i = skipWhitespace(json, start);
    const num_start = i;
    var has_exponent = false;

    while (i < json.len) {
        const c = json[i];
        if ((c >= '0' and c <= '9') or c == '.' or c == '-' or c == '+' or c == 'e' or c == 'E') {
            if (c == 'e' or c == 'E') has_exponent = true;
            i += 1;
        } else {
            break;
        }
    }

    if (i == num_start) return null;

    const num = json[num_start..i];
    const val = if (has_exponent)
        std.fmt.parseFloat(f64, num) catch return null
    else
        parseSimpleNumber(num) orelse return null;
    return NumberResult{ .val = val, .end = i };
}

fn extractString(json: []const u8, start: usize) ?StringResult {
    var i = skipWhitespace(json, start);
    if (i >= json.len or json[i] != '"') return null;
    i += 1;
    const str_start = i;
    const str_end = findChar(json, i, '"') orelse return null;
    return StringResult{ .val = json[str_start..str_end], .end = str_end + 1 };
}

fn extractBool(json: []const u8, start: usize) ?BoolResult {
    const i = skipWhitespace(json, start);
    if (i >= json.len) return null;

    if (json[i] == 't' and i + 4 <= json.len) {
        return BoolResult{ .val = true, .end = i + 4 };
    } else if (json[i] == 'f' and i + 5 <= json.len) {
        return BoolResult{ .val = false, .end = i + 5 };
    }
    return null;
}

fn parseStringArray(json: []const u8, start: usize, out: *[32][]const u8, count: *u8) usize {
    var i = skipWhitespace(json, start);
    if (i >= json.len or json[i] != '[') return i;
    i += 1;
    var c: u8 = 0;

    while (i < json.len and c < 32) {
        i = skipWhitespace(json, i);
        if (i >= json.len) break;
        if (json[i] == ']') {
            i += 1;
            break;
        }
        if (json[i] == ',') {
            i += 1;
            continue;
        }
        if (json[i] == '"') {
            i += 1;
            const str_start = i;
            const str_end = findChar(json, i, '"') orelse break;
            out[c] = json[str_start..str_end];
            c += 1;
            i = str_end + 1;
        } else {
            i += 1;
        }
    }
    count.* = c;
    return i;
}

fn findChar(json: []const u8, start: usize, char: u8) ?usize {
    var i = start;
    while (i < json.len) : (i += 1) {
        if (json[i] == char) return i;
    }
    return null;
}

fn skipWhitespace(json: []const u8, start: usize) usize {
    var i = start;
    while (i < json.len and (json[i] == ' ' or json[i] == '\t' or json[i] == '\n' or json[i] == '\r')) {
        i += 1;
    }
    return i;
}

test "parse basic payload" {
    const json =
        \\{
        \\  "id": "tx-3576980410",
        \\  "transaction": {
        \\    "amount": 384.88,
        \\    "installments": 3,
        \\    "requested_at": "2026-03-11T20:23:35Z"
        \\  },
        \\  "customer": {
        \\    "avg_amount": 769.76,
        \\    "tx_count_24h": 3,
        \\    "known_merchants": ["MERC-009", "MERC-001", "MERC-001"]
        \\  },
        \\  "merchant": {
        \\    "id": "MERC-001",
        \\    "mcc": "5912",
        \\    "avg_amount": 298.95
        \\  },
        \\  "terminal": {
        \\    "is_online": false,
        \\    "card_present": true,
        \\    "km_from_home": 13.7090520965
        \\  },
        \\  "last_transaction": {
        \\    "timestamp": "2026-03-11T14:58:35Z",
        \\    "km_from_current": 18.8626479774
        \\  }
        \\}
    ;

    const p = parse(json) orelse unreachable;
    try std.testing.expectApproxEqAbs(@as(f64, 384.88), p.amount, 0.01);
    try std.testing.expectApproxEqAbs(@as(f64, 3.0), p.installments, 0.01);
    try std.testing.expectEqualStrings("2026-03-11T20:23:35Z", p.requested_at);
    try std.testing.expectApproxEqAbs(@as(f64, 769.76), p.avg_amount, 0.01);
    try std.testing.expectEqual(@as(u8, 3), p.known_merchants_count);
    try std.testing.expectEqualStrings("MERC-001", p.merchant_id);
    try std.testing.expectEqualStrings("5912", p.mcc);
    try std.testing.expectApproxEqAbs(@as(f64, 298.95), p.merchant_avg_amount, 0.01);
    try std.testing.expect(!p.is_online);
    try std.testing.expect(p.card_present);
    try std.testing.expectApproxEqAbs(@as(f64, 13.709), p.km_from_home, 0.01);
    try std.testing.expect(p.has_last_tx);
    try std.testing.expectEqualStrings("2026-03-11T14:58:35Z", p.last_tx_timestamp);
    try std.testing.expectApproxEqAbs(@as(f64, 18.863), p.km_from_current, 0.01);
}

test "parse null last_transaction" {
    const json =
        \\{
        \\  "id": "tx-1329056812",
        \\  "transaction": {
        \\    "amount": 41.12,
        \\    "installments": 2,
        \\    "requested_at": "2026-03-11T18:45:53Z"
        \\  },
        \\  "customer": {
        \\    "avg_amount": 82.24,
        \\    "tx_count_24h": 3,
        \\    "known_merchants": ["MERC-003", "MERC-016"]
        \\  },
        \\  "merchant": {
        \\    "id": "MERC-016",
        \\    "mcc": "5411",
        \\    "avg_amount": 60.25
        \\  },
        \\  "terminal": {
        \\    "is_online": false,
        \\    "card_present": true,
        \\    "km_from_home": 29.2331036248
        \\  },
        \\  "last_transaction": null
        \\}
    ;

    const p = parse(json) orelse unreachable;
    try std.testing.expect(!p.has_last_tx);
    try std.testing.expectApproxEqAbs(@as(f64, 41.12), p.amount, 0.01);
}

test "extractNumber fast path decimal" {
    const result = extractNumber(" 384.88,", 0) orelse unreachable;
    try std.testing.expectApproxEqAbs(@as(f64, 384.88), result.val, 0.0001);
    try std.testing.expectEqual(@as(usize, 7), result.end);
}

test "extractNumber exponent fallback" {
    const result = extractNumber("1.25e2}", 0) orelse unreachable;
    try std.testing.expectApproxEqAbs(@as(f64, 125.0), result.val, 0.0001);
    try std.testing.expectEqual(@as(usize, 6), result.end);
}
