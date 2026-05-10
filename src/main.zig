const std = @import("std");
const linux = std.os.linux;
const dispatch = @import("dispatch.zig");
const io_server = @import("io_server.zig");
const profiler = @import("profiler.zig");
const responses = @import("responses.zig");
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

const RECV_BUF_SIZE: usize = 8192;
const DEFAULT_WORKER_COUNT: usize = 4;
const LISTEN_BACKLOG: u31 = 4096;

fn openTcpListener(port: u16) !i32 {
    const fd = try std.posix.socket(
        linux.AF.INET,
        linux.SOCK.STREAM | linux.SOCK.CLOEXEC,
        linux.IPPROTO.TCP,
    );
    errdefer std.posix.close(fd);

    const one: c_int = 1;
    try std.posix.setsockopt(fd, linux.SOL.SOCKET, linux.SO.REUSEADDR, std.mem.asBytes(&one));
    try std.posix.setsockopt(fd, linux.SOL.SOCKET, linux.SO.REUSEPORT, std.mem.asBytes(&one));
    try std.posix.setsockopt(fd, linux.IPPROTO.TCP, linux.TCP.NODELAY, std.mem.asBytes(&one));

    const addr = linux.sockaddr.in{
        .port = std.mem.nativeToBig(u16, port),
        .addr = 0,
    };
    try std.posix.bind(fd, @ptrCast(&addr), @sizeOf(linux.sockaddr.in));
    try std.posix.listen(fd, LISTEN_BACKLOG);
    return fd;
}

fn openUnixListener(path: []const u8) !i32 {
    if (std.fs.path.dirname(path)) |dir| {
        std.fs.cwd().makePath(dir) catch {};
    }
    std.fs.deleteFileAbsolute(path) catch |e| switch (e) {
        error.FileNotFound => {},
        else => return e,
    };

    const fd = try std.posix.socket(
        linux.AF.UNIX,
        linux.SOCK.STREAM | linux.SOCK.CLOEXEC,
        0,
    );
    errdefer std.posix.close(fd);

    var addr: linux.sockaddr.un = .{ .path = std.mem.zeroes([108]u8) };
    if (path.len >= addr.path.len) return error.SocketPathTooLong;
    @memcpy(addr.path[0..path.len], path);
    addr.path[path.len] = 0;
    const addrlen: linux.socklen_t = @intCast(@offsetOf(linux.sockaddr.un, "path") + path.len + 1);
    try std.posix.bind(fd, @ptrCast(&addr), addrlen);

    try std.posix.listen(fd, LISTEN_BACKLOG);
    return fd;
}

fn handleThreadedConnection(stream: std.net.Stream) void {
    defer stream.close();

    var recv_buf: [RECV_BUF_SIZE]u8 = undefined;
    var used: usize = 0;
    const ctx = dispatch.Context{ .set = &responses.close_set, .ready = ready };

    while (true) {
        const n = stream.read(recv_buf[used..]) catch return;
        if (n == 0) return;
        used += n;

        switch (dispatch.process(recv_buf[0..used], ctx)) {
            .response => |resp| {
                _ = stream.writeAll(resp) catch {};
                return;
            },
            .need_more => {
                if (used >= recv_buf.len) {
                    _ = stream.writeAll(ctx.set.bad_request) catch {};
                    return;
                }
            },
        }
    }
}

fn threadedWorkerLoop(listen_fd: i32) void {
    while (true) {
        var addr: linux.sockaddr = undefined;
        var addrlen: linux.socklen_t = @sizeOf(linux.sockaddr);
        const fd_res = linux.accept4(listen_fd, &addr, &addrlen, linux.SOCK.CLOEXEC);
        const fd_signed: i32 = @intCast(@as(isize, @bitCast(fd_res)));
        if (fd_signed < 0) continue;

        const stream = std.net.Stream{ .handle = fd_signed };
        handleThreadedConnection(stream);
    }
}

fn runThreaded(listen_fd: i32, worker_count: usize) !void {
    var spawned: usize = 1;
    while (spawned < worker_count) : (spawned += 1) {
        const thread = try std.Thread.spawn(.{}, threadedWorkerLoop, .{listen_fd});
        thread.detach();
    }
    threadedWorkerLoop(listen_fd);
}

const Backend = enum { uring, threaded };

fn pickBackend() Backend {
    const env = std.posix.getenv("IO_BACKEND") orelse return .uring;
    if (std.mem.eql(u8, env, "threaded")) return .threaded;
    if (std.mem.eql(u8, env, "uring")) return .uring;
    return .uring;
}

fn ignoreSigpipe() void {
    const act = linux.Sigaction{
        .handler = .{ .handler = linux.SIG.IGN },
        .mask = linux.empty_sigset,
        .flags = 0,
    };
    _ = linux.sigaction(linux.SIG.PIPE, &act, null);
}

pub fn main() !void {
    profiler.initFromEnv();
    ignoreSigpipe();

    const port: u16 = blk: {
        const port_str = std.posix.getenv("PORT") orelse "8080";
        break :blk std.fmt.parseInt(u16, port_str, 10) catch 8080;
    };
    const socket_path = std.posix.getenv("SOCKET_PATH");
    const data_dir = std.posix.getenv("DATA_DIR") orelse "/data";
    const worker_count = blk: {
        const worker_str = std.posix.getenv("HTTP_THREADS") orelse "4";
        const parsed = std.fmt.parseInt(usize, worker_str, 10) catch DEFAULT_WORKER_COUNT;
        break :blk @max(parsed, 1);
    };

    const backend = pickBackend();

    if (socket_path) |path| {
        std.log.info("Starting rinha-server backend={s} socket={s} data_dir={s}", .{ @tagName(backend), path, data_dir });
    } else {
        std.log.info("Starting rinha-server backend={s} port={d} data_dir={s}", .{ @tagName(backend), port, data_dir });
    }

    loadData(data_dir) catch |err| {
        std.log.err("Failed to load data: {any}", .{err});
        return err;
    };

    ready = true;

    const listen_fd: i32 = if (socket_path) |p|
        try openUnixListener(p)
    else
        try openTcpListener(port);
    defer std.posix.close(listen_fd);
    defer if (socket_path) |p| {
        std.fs.deleteFileAbsolute(p) catch {};
    };

    switch (backend) {
        .uring => {
            io_server.run(listen_fd, &ready) catch |err| {
                std.log.err("io_uring transport failed ({any}); falling back to threaded", .{err});
                try runThreaded(listen_fd, worker_count);
            };
        },
        .threaded => {
            try runThreaded(listen_fd, worker_count);
        },
    }
}

test {
    _ = @import("time_utils.zig");
    _ = @import("vectorize.zig");
    _ = @import("json_fast.zig");
    _ = @import("dispatch.zig");
    _ = @import("io_server.zig");
}
