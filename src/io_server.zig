const std = @import("std");
const linux = std.os.linux;
const dispatch = @import("dispatch.zig");
const responses = @import("responses.zig");

const RING_ENTRIES: u16 = 4096;

pub const MAX_CONNS: u16 = 1024;

const RECV_CAP: u16 = 4096;

const FREE_END: u16 = std.math.maxInt(u16);

const Conn = struct {
    fd: i32 = -1,
    used: u16 = 0,
    write_off: u32 = 0,
    write_total: u32 = 0,
    write_ptr: [*]const u8 = undefined,
    next_free: u16 = FREE_END,
    buf: [RECV_CAP]u8 = undefined,
};

const ConnPool = struct {
    slots: [MAX_CONNS]Conn = [_]Conn{.{}} ** MAX_CONNS,
    free_head: u16 = 0,

    fn init(self: *ConnPool) void {
        var i: u16 = 0;
        while (i < MAX_CONNS) : (i += 1) {
            self.slots[i] = .{};
            self.slots[i].next_free = if (i + 1 < MAX_CONNS) i + 1 else FREE_END;
        }
        self.free_head = 0;
    }

    fn acquire(self: *ConnPool, fd: i32) ?u16 {
        if (self.free_head == FREE_END) return null;
        const id = self.free_head;
        const slot = &self.slots[id];
        self.free_head = slot.next_free;
        slot.* = .{ .fd = fd };
        return id;
    }

    fn release(self: *ConnPool, id: u16) void {
        const slot = &self.slots[id];
        // Idempotent: a failed linked send + cancelled recv pair can both
        // call release for the same id. fd == -1 is the released marker.
        if (slot.fd < 0) return;
        _ = linux.close(slot.fd);
        slot.fd = -1;
        slot.used = 0;
        slot.write_off = 0;
        slot.write_total = 0;
        slot.next_free = self.free_head;
        self.free_head = id;
    }
};

const Op = enum(u8) {
    accept = 0,
    recv = 1,
    send = 2,
};

inline fn pack(op: Op, id: u16) u64 {
    return (@as(u64, @intFromEnum(op)) << 16) | @as(u64, id);
}

inline fn opOf(ud: u64) Op {
    return @enumFromInt(@as(u8, @truncate(ud >> 16)));
}

inline fn idOf(ud: u64) u16 {
    return @truncate(ud);
}

fn initRing() !linux.IoUring {
    var params: linux.io_uring_params = std.mem.zeroes(linux.io_uring_params);
    params.flags =
        linux.IORING_SETUP_SINGLE_ISSUER |
        linux.IORING_SETUP_DEFER_TASKRUN |
        linux.IORING_SETUP_COOP_TASKRUN;

    return linux.IoUring.init_params(RING_ENTRIES, &params) catch {
        var fb: linux.io_uring_params = std.mem.zeroes(linux.io_uring_params);
        return linux.IoUring.init_params(RING_ENTRIES, &fb);
    };
}

var accept_addr: linux.sockaddr = undefined;
var accept_addr_len: linux.socklen_t = @sizeOf(linux.sockaddr);

pub fn run(listen_fd: i32, ready_flag: *const bool) !void {
    var ring = try initRing();
    defer ring.deinit();

    var pool: ConnPool = undefined;
    pool.init();

    try armAccept(&ring, listen_fd);

    while (true) {
        _ = try ring.submit_and_wait(1);
        var head = ring.cq.head.*;
        const tail = @atomicLoad(u32, ring.cq.tail, .acquire);
        while (head != tail) : (head +%= 1) {
            const cqe = ring.cq.cqes[head & ring.cq.mask];
            handleCqe(&ring, &pool, listen_fd, ready_flag.*, cqe) catch |err| {
                std.log.err("io_uring cqe dispatch: {any}", .{err});
            };
        }
        @atomicStore(u32, ring.cq.head, head, .release);
    }
}

fn handleCqe(
    ring: *linux.IoUring,
    pool: *ConnPool,
    listen_fd: i32,
    ready: bool,
    cqe: linux.io_uring_cqe,
) !void {
    switch (opOf(cqe.user_data)) {
        .accept => try onAccept(ring, pool, listen_fd, cqe),
        .recv => try onRecv(ring, pool, ready, cqe),
        .send => try onSend(ring, pool, cqe),
    }
}

fn armAccept(ring: *linux.IoUring, listen_fd: i32) !void {
    const sqe = try ring.get_sqe();
    sqe.prep_multishot_accept(listen_fd, &accept_addr, &accept_addr_len, 0);
    sqe.user_data = pack(.accept, 0);
}

fn onAccept(
    ring: *linux.IoUring,
    pool: *ConnPool,
    listen_fd: i32,
    cqe: linux.io_uring_cqe,
) !void {
    const more = (cqe.flags & linux.IORING_CQE_F_MORE) != 0;
    if (!more) {
        try armAccept(ring, listen_fd);
    }

    if (cqe.res < 0) return;
    const fd: i32 = cqe.res;

    const id = pool.acquire(fd) orelse {
        _ = linux.close(fd);
        return;
    };

    try armRecv(ring, pool, id, 0);
}

fn armRecv(ring: *linux.IoUring, pool: *ConnPool, id: u16, offset: u16) !void {
    const slot = &pool.slots[id];
    const sqe = try ring.get_sqe();
    sqe.prep_recv(slot.fd, slot.buf[offset..], 0);
    sqe.user_data = pack(.recv, id);
}

fn onRecv(
    ring: *linux.IoUring,
    pool: *ConnPool,
    ready: bool,
    cqe: linux.io_uring_cqe,
) !void {
    const id = idOf(cqe.user_data);
    const slot = &pool.slots[id];

    if (cqe.res <= 0) {
        pool.release(id);
        return;
    }
    const got: u16 = @intCast(@as(u32, @bitCast(cqe.res)));
    slot.used += got;

    const ctx = dispatch.Context{ .set = &responses.ka_set, .ready = ready };
    switch (dispatch.process(slot.buf[0..slot.used], ctx)) {
        .response => |resp| try beginSend(ring, pool, id, resp),
        .need_more => {
            if (slot.used >= RECV_CAP) {
                try beginSend(ring, pool, id, ctx.set.bad_request);
                return;
            }
            try armRecv(ring, pool, id, slot.used);
        },
    }
}

fn beginSend(ring: *linux.IoUring, pool: *ConnPool, id: u16, resp: []const u8) !void {
    const slot = &pool.slots[id];
    slot.write_ptr = resp.ptr;
    slot.write_total = @intCast(resp.len);
    slot.write_off = 0;
    const sqe = try ring.get_sqe();
    sqe.prep_send(slot.fd, resp, 0);
    sqe.user_data = pack(.send, id);
}

fn onSend(ring: *linux.IoUring, pool: *ConnPool, cqe: linux.io_uring_cqe) !void {
    const id = idOf(cqe.user_data);
    const slot = &pool.slots[id];

    if (cqe.res <= 0) {
        pool.release(id);
        return;
    }
    const sent: u32 = @intCast(@as(u32, @bitCast(cqe.res)));
    slot.write_off += sent;

    if (slot.write_off < slot.write_total) {
        const remaining = slot.write_ptr[slot.write_off..slot.write_total];
        const sqe = try ring.get_sqe();
        sqe.prep_send(slot.fd, remaining, 0);
        sqe.user_data = pack(.send, id);
        return;
    }
    slot.used = 0;
    slot.write_off = 0;
    slot.write_total = 0;
    try armRecv(ring, pool, id, 0);
}

test "ConnPool acquire reuses freed slot LIFO" {
    var pool: ConnPool = undefined;
    pool.init();

    const a = pool.acquire(10).?;
    const b = pool.acquire(11).?;
    try std.testing.expect(a != b);

    pool.release(a);
    const c = pool.acquire(12).?;
    try std.testing.expectEqual(a, c); // LIFO: last freed is next acquired
}

test "ConnPool fills capacity then refuses" {
    var pool: ConnPool = undefined;
    pool.init();

    var i: u16 = 0;
    while (i < MAX_CONNS) : (i += 1) {
        _ = pool.acquire(@as(i32, i) + 1).?;
    }
    try std.testing.expectEqual(@as(?u16, null), pool.acquire(99));

    for (&pool.slots) |*s| s.fd = -1;
}

test "pack/unpack roundtrip preserves op and id" {
    const ud = pack(.send, 0xBEEF);
    try std.testing.expectEqual(Op.send, opOf(ud));
    try std.testing.expectEqual(@as(u16, 0xBEEF), idOf(ud));
}
