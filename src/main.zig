const std = @import("std");
const json_fast = @import("json_fast.zig");
const vectorize = @import("vectorize.zig");
const vector_core = @import("vector_core.zig");

var ready: bool = false;

fn loadData(data_dir: []const u8) !void {
    var vec_path_buf: [256:0]u8 = undefined;
    const vec_path = try std.fmt.bufPrintZ(&vec_path_buf, "{s}/vectors.bin", .{data_dir});

    var lab_path_buf: [256:0]u8 = undefined;
    const lab_path = try std.fmt.bufPrintZ(&lab_path_buf, "{s}/labels.bin", .{data_dir});

    var res_path_buf: [256:0]u8 = undefined;
    const res_path = try std.fmt.bufPrintZ(&res_path_buf, "{s}/residuals.bin", .{data_dir});

    var ivf_path_buf: [256:0]u8 = undefined;
    const ivf_path = try std.fmt.bufPrintZ(&ivf_path_buf, "{s}/ivf.bin", .{data_dir});

    if (vector_core.vc_init(vec_path.ptr, lab_path.ptr, res_path.ptr, ivf_path.ptr) != 0) {
        return error.IndexInitFailed;
    }

    std.log.info("Data loaded: {d} indexed vectors", .{vector_core.vc_count()});
}

const RECV_BUF_SIZE = 8192;
const MAX_BODY_SIZE = 4096;
const DEFAULT_WORKER_COUNT: usize = 4;

// Pre-formatted responses
const RESP_OK = "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 2\r\nConnection: close\r\n\r\nOK";
const RESP_503 = "HTTP/1.1 503 Service Unavailable\r\nContent-Type: text/plain\r\nContent-Length: 7\r\nConnection: close\r\n\r\nLoading";
const RESP_400 = "HTTP/1.1 400 Bad Request\r\nContent-Type: text/plain\r\nContent-Length: 11\r\nConnection: close\r\n\r\nbad request";
const RESP_404 = "HTTP/1.1 404 Not Found\r\nContent-Type: text/plain\r\nContent-Length: 9\r\nConnection: close\r\n\r\nNot Found";
const RESP_FALLBACK = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 35\r\nConnection: close\r\n\r\n{\"approved\":true,\"fraud_score\":0.0}";
const RESP_FRAUD_SCORES = [_][]const u8{
    "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 35\r\nConnection: close\r\n\r\n{\"approved\":true,\"fraud_score\":0.0}",
    "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 35\r\nConnection: close\r\n\r\n{\"approved\":true,\"fraud_score\":0.2}",
    "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 35\r\nConnection: close\r\n\r\n{\"approved\":true,\"fraud_score\":0.4}",
    "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 36\r\nConnection: close\r\n\r\n{\"approved\":false,\"fraud_score\":0.6}",
    "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 36\r\nConnection: close\r\n\r\n{\"approved\":false,\"fraud_score\":0.8}",
    "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 36\r\nConnection: close\r\n\r\n{\"approved\":false,\"fraud_score\":1.0}",
};

const Route = enum {
    ready,
    fraud_score,
    unknown,
};

const ReadRequestResult = union(enum) {
    complete: []const u8,
    bad_request: void,
    closed: void,
};

fn writeResponse(stream: std.net.Stream, response: []const u8) void {
    stream.writeAll(response) catch {};
}

fn findHeaderEnd(request: []const u8) ?usize {
    if (request.len < 4) return null;

    var i: usize = 0;
    while (i + 3 < request.len) : (i += 1) {
        if (request[i] == '\r' and request[i + 1] == '\n' and request[i + 2] == '\r' and request[i + 3] == '\n') {
            return i + 4;
        }
    }

    return null;
}

fn parseContentLength(request: []const u8, header_end: usize) usize {
    const tag = "content-length:";
    if (header_end <= tag.len) return 0;

    var i: usize = 0;
    while (i + tag.len < header_end) : (i += 1) {
        const line_start = i == 0 or (i >= 2 and request[i - 2] == '\r' and request[i - 1] == '\n');
        if (!line_start) continue;

        var matches = true;
        for (tag, 0..) |expected, offset| {
            var actual = request[i + offset];
            if (actual >= 'A' and actual <= 'Z') actual |= 0x20;
            if (actual != expected) {
                matches = false;
                break;
            }
        }

        if (!matches) continue;

        var cursor = i + tag.len;
        while (cursor < header_end and (request[cursor] == ' ' or request[cursor] == '\t')) : (cursor += 1) {}

        var value: usize = 0;
        while (cursor < header_end and request[cursor] >= '0' and request[cursor] <= '9') : (cursor += 1) {
            value = (value * 10) + (request[cursor] - '0');
        }

        return value;
    }

    return 0;
}

fn readRequest(stream: std.net.Stream, recv_buf: []u8) ReadRequestResult {
    var used: usize = 0;

    while (used < recv_buf.len) {
        const n_read = stream.read(recv_buf[used..]) catch return .closed;
        if (n_read == 0) return if (used == 0) .closed else .bad_request;
        used += n_read;

        const header_end = findHeaderEnd(recv_buf[0..used]) orelse continue;
        const body_len = parseContentLength(recv_buf[0..used], header_end);
        if (body_len > MAX_BODY_SIZE) return .bad_request;

        const total_len = header_end + body_len;
        if (total_len > recv_buf.len) return .bad_request;
        if (used >= total_len) return .{ .complete = recv_buf[0..total_len] };
    }

    return .bad_request;
}

fn routeRequest(request: []const u8) Route {
    if (request.len >= 18 and std.mem.startsWith(u8, request, "POST /fraud-score ")) return .fraud_score;
    if (request.len >= 11 and std.mem.startsWith(u8, request, "GET /ready ")) return .ready;
    return .unknown;
}

fn handleConnection(stream: std.net.Stream) void {
    defer stream.close();

    var recv_buf: [RECV_BUF_SIZE]u8 = undefined;

    const request = switch (readRequest(stream, &recv_buf)) {
        .closed => return,
        .bad_request => {
            writeResponse(stream, RESP_400);
            return;
        },
        .complete => |complete| complete,
    };

    switch (routeRequest(request)) {
        .ready => {
            writeResponse(stream, if (ready) RESP_OK else RESP_503);
        },
        .fraud_score => {
            handleFraudScore(request, stream);
        },
        .unknown => {
            writeResponse(stream, RESP_404);
        },
    }
}

fn handleFraudScore(request: []const u8, stream: std.net.Stream) void {
    const body = findBody(request) orelse {
        writeResponse(stream, RESP_FALLBACK);
        return;
    };

    // Parse JSON
    const payload = json_fast.parse(body) orelse {
        writeResponse(stream, RESP_FALLBACK);
        return;
    };

    // Vectorize
    const query_vec = vectorize.vectorize(&payload);

    const max_score: c_int = @intCast(RESP_FRAUD_SCORES.len);
    const raw_count = vector_core.vc_query(query_vec[0..].ptr);
    const fraud_count: usize = if (raw_count < 0 or raw_count >= max_score) 0 else @intCast(raw_count);

    writeResponse(stream, RESP_FRAUD_SCORES[fraud_count]);
}

fn findBody(request: []const u8) ?[]const u8 {
    const header_end = findHeaderEnd(request) orelse return null;
    return request[header_end..];
}

fn runWorker(server: *std.net.Server) !void {
    while (true) {
        const conn = server.accept() catch |err| switch (err) {
            error.ConnectionAborted => continue,
            else => return err,
        };

        handleConnection(conn.stream);
    }
}

fn workerMain(server: *std.net.Server) void {
    runWorker(server) catch |err| {
        std.log.err("worker stopped: {any}", .{err});
    };
}

pub fn main() !void {
    const port: u16 = blk: {
        const port_str = std.posix.getenv("PORT") orelse "8080";
        break :blk std.fmt.parseInt(u16, port_str, 10) catch 8080;
    };
    const data_dir = std.posix.getenv("DATA_DIR") orelse "/data";
    const worker_count = blk: {
        const worker_str = std.posix.getenv("HTTP_THREADS") orelse "4";
        const parsed = std.fmt.parseInt(usize, worker_str, 10) catch DEFAULT_WORKER_COUNT;
        break :blk @max(parsed, 1);
    };

    std.log.info("Starting rinha-server on port {d}, data_dir={s}, workers={d}", .{ port, data_dir, worker_count });

    // Load preprocessed data
    loadData(data_dir) catch |err| {
        std.log.err("Failed to load data: {any}", .{err});
        return err;
    };

    ready = true;
    std.log.info("Server ready on port {d}", .{port});

    const address = std.net.Address.parseIp4("0.0.0.0", port) catch unreachable;
    var server = try address.listen(.{
        .reuse_address = true,
        .kernel_backlog = 4096,
    });
    defer server.deinit();

    var spawned_threads: usize = 1;
    while (spawned_threads < worker_count) : (spawned_threads += 1) {
        const thread = try std.Thread.spawn(.{}, workerMain, .{&server});
        thread.detach();
    }

    try runWorker(&server);
}

test "findBody basic" {
    const req = "POST /fraud-score HTTP/1.1\r\nContent-Length: 5\r\n\r\nhello";
    const body = findBody(req);
    try std.testing.expect(body != null);
    try std.testing.expectEqualStrings("hello", body.?);
}

test "findBody no body" {
    const req = "GET /ready HTTP/1.1\r\n";
    try std.testing.expect(findBody(req) == null);
}

test {
    // Run all imported module tests
    _ = @import("time_utils.zig");
    _ = @import("vectorize.zig");
    _ = @import("json_fast.zig");
}
