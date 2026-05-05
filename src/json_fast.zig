const std = @import("std");
const vectorize = @import("vectorize.zig");

const Payload = vectorize.Payload;

pub fn parse(json: []const u8) ?Payload {
    var p = Payload{};
    var i: usize = 0;
    var in_last_transaction = false;
    var last_tx_null = true;

    while (i < json.len) {
        if (json[i] == '"') {
            const key_start = i + 1;
            const key_end = findChar(json, key_start, '"') orelse break;
            const key = json[key_start..key_end];
            i = key_end + 1;

            i = skipWhitespace(json, i);
            if (i >= json.len or json[i] != ':') {
                i += 1;
                continue;
            }
            i += 1;
            i = skipWhitespace(json, i);

            if (std.mem.eql(u8, key, "last_transaction")) {
                if (i < json.len and json[i] == 'n') {
                    in_last_transaction = false;
                    last_tx_null = true;
                    p.has_last_tx = false;
                    i += 4;
                    continue;
                } else if (i < json.len and json[i] == '{') {
                    in_last_transaction = true;
                    last_tx_null = false;
                    p.has_last_tx = true;
                    i += 1;
                    continue;
                }
            }

            if (in_last_transaction) {
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
            } else {
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
                } else if (std.mem.eql(u8, key, "avg_amount")) {
                    if (extractNumber(json, i)) |n| {
                        if (p.merchant_id.len > 0) {
                            p.merchant_avg_amount = n.val;
                        } else {
                            p.avg_amount = n.val;
                        }
                        i = n.end;
                    }
                } else if (std.mem.eql(u8, key, "tx_count_24h")) {
                    if (extractNumber(json, i)) |n| {
                        p.tx_count_24h = n.val;
                        i = n.end;
                    }
                } else if (std.mem.eql(u8, key, "known_merchants")) {
                    i = parseStringArray(json, i, &p.known_merchants, &p.known_merchants_count);
                } else if (std.mem.eql(u8, key, "id")) {
                    if (extractString(json, i)) |s| {
                        if (lookBackForKey(json, key_start, "merchant")) {
                            p.merchant_id = s.val;
                        }

                        i = s.end;
                    }
                } else if (std.mem.eql(u8, key, "mcc")) {
                    if (extractString(json, i)) |s| {
                        p.mcc = s.val;
                        i = s.end;
                    }
                } else if (std.mem.eql(u8, key, "is_online")) {
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
            }
        } else if (json[i] == '}' and in_last_transaction) {
            in_last_transaction = false;
            i += 1;
        } else {
            i += 1;
        }
    }

    if (!last_tx_null) {
        p.has_last_tx = true;
    }

    return p;
}

const NumberResult = struct { val: f64, end: usize };
const StringResult = struct { val: []const u8, end: usize };
const BoolResult = struct { val: bool, end: usize };

fn extractNumber(json: []const u8, start: usize) ?NumberResult {
    var i = skipWhitespace(json, start);
    const num_start = i;

    while (i < json.len) {
        const c = json[i];
        if ((c >= '0' and c <= '9') or c == '.' or c == '-' or c == '+' or c == 'e' or c == 'E') {
            i += 1;
        } else {
            break;
        }
    }

    if (i == num_start) return null;

    const val = std.fmt.parseFloat(f64, json[num_start..i]) catch return null;
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

fn lookBackForKey(json: []const u8, pos: usize, key: []const u8) bool {
    if (pos < key.len + 5) return false;
    var i = pos - 1;

    var depth: i32 = 0;
    var found_brace = false;
    while (i > 0) : (i -= 1) {
        const c = json[i];
        if (c == '{') {
            found_brace = true;
            break;
        }
        if (c == '}') {
            depth += 1;
        }
        if (depth > 0) continue;
        if (i < key.len + 3) return false;
    }
    if (!found_brace or i < key.len + 3) return false;

    var j = i;
    while (j > 0) : (j -= 1) {
        if (json[j] == '"') {
            const end = j;
            if (j < key.len) return false;
            const start = end - key.len;
            if (start > 0 and json[start - 1] == '"') {
                return std.mem.eql(u8, json[start..end], key);
            }
            return false;
        }
    }
    return false;
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
