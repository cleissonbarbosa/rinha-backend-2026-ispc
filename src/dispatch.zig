const std = @import("std");
const json_fast = @import("json_fast.zig");
const profiler = @import("profiler.zig");
const vectorize = @import("vectorize.zig");
const vector_core = @import("vector_core.zig");
const responses = @import("responses.zig");

const MAX_BODY: usize = 4096;

pub const Outcome = union(enum) {
    need_more: void,
    response: []const u8,
};

pub const Context = struct {
    set: *const responses.ResponseSet,
    ready: bool,
};

inline fn findCRLFCRLF(buf: []const u8) ?usize {
    if (buf.len < 4) return null;
    var i: usize = 0;
    while (i + 4 <= buf.len) : (i += 1) {
        if (buf[i] == '\r' and buf[i + 1] == '\n' and buf[i + 2] == '\r' and buf[i + 3] == '\n') {
            return i + 4;
        }
    }
    return null;
}

fn parseContentLength(headers: []const u8) usize {
    const tag = "content-length:";
    if (headers.len < tag.len) return 0;

    var i: usize = 0;
    while (i + tag.len <= headers.len) : (i += 1) {
        const at_line_start = i == 0 or (i >= 2 and headers[i - 2] == '\r' and headers[i - 1] == '\n');
        if (!at_line_start) continue;

        var matches = true;
        for (tag, 0..) |expected, off| {
            var actual = headers[i + off];
            if (actual >= 'A' and actual <= 'Z') actual |= 0x20;
            if (actual != expected) {
                matches = false;
                break;
            }
        }
        if (!matches) continue;

        var p = i + tag.len;
        while (p < headers.len and (headers[p] == ' ' or headers[p] == '\t')) : (p += 1) {}

        var v: usize = 0;
        while (p < headers.len and headers[p] >= '0' and headers[p] <= '9') : (p += 1) {
            v = v * 10 + @as(usize, headers[p] - '0');
        }
        return v;
    }
    return 0;
}

const Method = enum { get, post, other };

inline fn detectMethod(buf: []const u8) Method {
    if (buf.len >= 4 and std.mem.eql(u8, buf[0..4], "GET ")) return .get;
    if (buf.len >= 5 and std.mem.eql(u8, buf[0..5], "POST ")) return .post;
    return .other;
}

pub fn process(buf: []const u8, ctx: Context) Outcome {
    var scope = profiler.Scope.start();
    const headers_end = findCRLFCRLF(buf) orelse return .need_more;
    scope.lap(.find_body);
    const headers = buf[0..headers_end];

    const method = detectMethod(buf);
    if (method == .other) return .{ .response = ctx.set.bad_request };

    const cl = parseContentLength(headers);
    if (cl > MAX_BODY) return .{ .response = ctx.set.bad_request };

    const body_start = headers_end;
    const total = body_start + cl;
    if (buf.len < total) return .need_more;

    const resp = route(buf[0..total], headers_end, ctx);
    scope.finish(.fraud_total);
    return .{ .response = resp };
}

inline fn route(req: []const u8, headers_end: usize, ctx: Context) []const u8 {
    if (req.len >= 18 and std.mem.startsWith(u8, req, "POST /fraud-score ")) {
        return runFraudScore(req[headers_end..], ctx);
    }
    if (req.len >= 11 and std.mem.startsWith(u8, req, "GET /ready ")) {
        return if (ctx.ready) ctx.set.ready else ctx.set.not_ready;
    }
    return ctx.set.not_found;
}

fn runFraudScore(body: []const u8, ctx: Context) []const u8 {
    var scope = profiler.Scope.start();
    const payload = json_fast.parse(body) orelse return ctx.set.fallback_ok;
    scope.lap(.parse_json);
    const query_vec = vectorize.vectorize(&payload);
    scope.lap(.vectorize);
    const raw_count = vector_core.vc_query(query_vec[0..].ptr);
    scope.lap(.core_query);
    const max_score: c_int = @intCast(ctx.set.fraud.len);
    const fraud_count: usize = if (raw_count < 0 or raw_count >= max_score)
        0
    else
        @intCast(raw_count);
    scope.lap(.write_response);
    return ctx.set.fraud[fraud_count];
}

test "process returns need_more on incomplete headers" {
    const ctx = Context{ .set = &responses.ka_set, .ready = true };
    const r = process("GET /ready", ctx);
    try std.testing.expect(r == .need_more);
}

test "process routes /ready when ready" {
    const ctx = Context{ .set = &responses.ka_set, .ready = true };
    const r = process("GET /ready HTTP/1.1\r\n\r\n", ctx);
    try std.testing.expectEqualStrings(responses.ka.ready, r.response);
}

test "process routes /ready as not_ready when not ready" {
    const ctx = Context{ .set = &responses.ka_set, .ready = false };
    const r = process("GET /ready HTTP/1.1\r\n\r\n", ctx);
    try std.testing.expectEqualStrings(responses.ka.not_ready, r.response);
}

test "process returns need_more when body short of Content-Length" {
    const ctx = Context{ .set = &responses.ka_set, .ready = true };
    const r = process("POST /fraud-score HTTP/1.1\r\nContent-Length: 100\r\n\r\nshort", ctx);
    try std.testing.expect(r == .need_more);
}

test "process rejects oversized Content-Length" {
    const ctx = Context{ .set = &responses.ka_set, .ready = true };
    const r = process("POST /fraud-score HTTP/1.1\r\nContent-Length: 999999\r\n\r\n", ctx);
    try std.testing.expectEqualStrings(responses.ka.bad_request, r.response);
}

test "parseContentLength is case insensitive and handles whitespace" {
    try std.testing.expectEqual(@as(usize, 42), parseContentLength("Content-Length:   42\r\n"));
    try std.testing.expectEqual(@as(usize, 7), parseContentLength("CONTENT-LENGTH:7\r\n"));
    try std.testing.expectEqual(@as(usize, 0), parseContentLength("X-Other: 5\r\n"));
}
