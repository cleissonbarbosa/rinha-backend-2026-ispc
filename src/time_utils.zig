const std = @import("std");

pub const Timestamp = struct {
    year: u16,
    month: u8,
    day: u8,
    hour: u8,
    minute: u8,
    second: u8,
};

pub fn parseTimestamp(s: []const u8) ?Timestamp {
    if (s.len < 19) return null;

    const year = parseInt4(s[0..4]) orelse return null;
    const month = parseInt2(s[5..7]) orelse return null;
    const day = parseInt2(s[8..10]) orelse return null;
    const hour = parseInt2(s[11..13]) orelse return null;
    const minute = parseInt2(s[14..16]) orelse return null;
    const second = parseInt2(s[17..19]) orelse return null;

    return Timestamp{
        .year = year,
        .month = month,
        .day = day,
        .hour = hour,
        .minute = minute,
        .second = second,
    };
}

fn parseInt2(s: *const [2]u8) ?u8 {
    const d0 = s[0] -% '0';
    const d1 = s[1] -% '0';
    if (d0 > 9 or d1 > 9) return null;
    return d0 * 10 + d1;
}

fn parseInt4(s: *const [4]u8) ?u16 {
    const d0: u16 = s[0] -% '0';
    const d1: u16 = s[1] -% '0';
    const d2: u16 = s[2] -% '0';
    const d3: u16 = s[3] -% '0';
    if (d0 > 9 or d1 > 9 or d2 > 9 or d3 > 9) return null;
    return d0 * 1000 + d1 * 100 + d2 * 10 + d3;
}

pub fn dayOfWeek(year_in: u16, month: u8, day: u8) u8 {
    const y: i32 = @intCast(year_in);
    const m: i32 = @intCast(month);
    const d: i32 = @intCast(day);

    const t = [_]i32{ 0, 3, 2, 5, 0, 3, 5, 1, 4, 6, 2, 4 };

    var adj_y = y;
    if (m < 3) adj_y -= 1;

    const idx: usize = @intCast(m - 1);
    const raw = @mod(adj_y + @divFloor(adj_y, 4) - @divFloor(adj_y, 100) + @divFloor(adj_y, 400) + t[idx] + d, 7);

    const result: u8 = @intCast(@mod(raw + 6, 7));
    return result;
}

pub fn toMinutes(ts: Timestamp) i64 {
    const y: i64 = @intCast(ts.year);
    const m: i64 = @intCast(ts.month);
    const d: i64 = @intCast(ts.day);
    const h: i64 = @intCast(ts.hour);
    const min: i64 = @intCast(ts.minute);

    var days: i64 = 365 * y + @divFloor(y, 4) - @divFloor(y, 100) + @divFloor(y, 400);

    const month_days = [_]i64{ 0, 31, 59, 90, 120, 151, 181, 212, 243, 273, 304, 334 };
    const m_idx: usize = @intCast(m - 1);
    days += month_days[m_idx];

    if (m > 2) {
        const is_leap = (@mod(y, 4) == 0 and @mod(y, 100) != 0) or @mod(y, 400) == 0;
        if (is_leap) days += 1;
    }

    days += d;

    return days * 1440 + h * 60 + min;
}

pub fn minutesBetween(a: Timestamp, b: Timestamp) f64 {
    const a_min = toMinutes(a);
    const b_min = toMinutes(b);

    const a_sec: i64 = @intCast(a.second);
    const b_sec: i64 = @intCast(b.second);

    const diff_seconds = (a_min - b_min) * 60 + (a_sec - b_sec);
    const abs_diff: f64 = @floatFromInt(if (diff_seconds < 0) -diff_seconds else diff_seconds);
    return abs_diff / 60.0;
}

test "parseTimestamp valid" {
    const ts = parseTimestamp("2026-03-11T20:23:35Z").?;
    try std.testing.expectEqual(@as(u16, 2026), ts.year);
    try std.testing.expectEqual(@as(u8, 3), ts.month);
    try std.testing.expectEqual(@as(u8, 11), ts.day);
    try std.testing.expectEqual(@as(u8, 20), ts.hour);
    try std.testing.expectEqual(@as(u8, 23), ts.minute);
    try std.testing.expectEqual(@as(u8, 35), ts.second);
}

test "parseTimestamp too short" {
    try std.testing.expect(parseTimestamp("short") == null);
}

test "dayOfWeek Wednesday 2026-03-11" {
    const dow = dayOfWeek(2026, 3, 11);
    try std.testing.expectEqual(@as(u8, 2), dow);
}

test "dayOfWeek Monday" {
    const dow = dayOfWeek(2026, 3, 9);
    try std.testing.expectEqual(@as(u8, 0), dow);
}

test "dayOfWeek Sunday" {
    const dow = dayOfWeek(2026, 3, 15);
    try std.testing.expectEqual(@as(u8, 6), dow);
}

test "dayOfWeek Saturday 2026-03-14" {
    const dow = dayOfWeek(2026, 3, 14);
    try std.testing.expectEqual(@as(u8, 5), dow);
}

test "minutesBetween same timestamp" {
    const ts = Timestamp{ .year = 2026, .month = 3, .day = 11, .hour = 20, .minute = 23, .second = 35 };
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), minutesBetween(ts, ts), 0.01);
}

test "minutesBetween 5h25m difference" {
    const a = parseTimestamp("2026-03-11T20:23:35Z").?;
    const b = parseTimestamp("2026-03-11T14:58:35Z").?;
    const diff = minutesBetween(a, b);
    try std.testing.expectApproxEqAbs(@as(f64, 325.0), diff, 0.01);
}
