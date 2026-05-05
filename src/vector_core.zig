const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const posix = std.posix;

const D: usize = 14;
const K: usize = 5;
const TOP_C: usize = 16;
const VLEN: usize = 16;
const AVX2_LANES: usize = 8;
const MAX_NPROBE: usize = 24;
const MAX_CLUSTERS: usize = 8192;
const ISPC_DISTANCE_BLOCK: usize = 1024;
const IVF_MAGIC = "RIVF2026";
const Q16_SCALE: f32 = 32767.0;
const REFINE_STEP: i32 = 128;
const REFINE_SCALE: f32 = Q16_SCALE * @as(f32, @floatFromInt(REFINE_STEP));
const REFINE_MIN: i32 = -32767 * REFINE_STEP;
const REFINE_MAX: i32 = 32767 * REFINE_STEP;
const COARSE_TIE_GAP: f32 = 512.0;

const Vec32 = @Vector(AVX2_LANES, f32);
const Vec16 = @Vector(AVX2_LANES, i16);

comptime {
    std.debug.assert(VLEN == AVX2_LANES * 2);
    _ = builtin;
}

var n_vecs: usize = 0;
var n_clusters: usize = 0;
var nprobe: usize = 0;
var dims_data: [*]align(64) const i16 = undefined;
var residuals_data: [*]const u8 = undefined;
var labels_data: [*]const u8 = undefined;
var centroids_data: [*]align(4) const f32 = undefined;
var radii_data: [*]align(4) const f32 = undefined;
var boundaries_data: [*]align(4) const u32 = undefined;

extern fn vc_centroid_dists_ispc(query: [*]const i16, centroids: [*]const f32, cluster_count: c_int, out_dists: [*]f32) void;
extern fn vc_scan_top_q16_ispc(query: [*]const i16, dims: [*]const i16, n_vectors: c_int, start_idx: c_int, count: c_int, out_idx: [*]u32, out_dists: [*]f32) void;

inline fn readU32LE(mem: []align(std.mem.page_size) const u8, offset: usize) u32 {
    return @as(u32, mem[offset]) |
        (@as(u32, mem[offset + 1]) << 8) |
        (@as(u32, mem[offset + 2]) << 16) |
        (@as(u32, mem[offset + 3]) << 24);
}

fn mmapRO(path: []const u8, expected_align: usize) ![]align(std.mem.page_size) const u8 {
    _ = expected_align;
    const fd = try posix.open(path, .{ .ACCMODE = .RDONLY }, 0);
    defer posix.close(fd);

    const st = try posix.fstat(fd);
    const size: usize = @intCast(st.size);

    const mem = try posix.mmap(
        null,
        size,
        posix.PROT.READ,
        .{ .TYPE = .SHARED },
        fd,
        0,
    );
    posix.madvise(mem.ptr, size, posix.MADV.WILLNEED) catch {};

    const page_size = std.mem.page_size;
    var fault_sink: u8 = 0;
    var off: usize = 0;
    while (off < size) : (off += page_size) {
        fault_sink ^= mem[off];
    }
    asm volatile (""
        :
        : [s] "r" (fault_sink),
        : "memory");

    return mem[0..size];
}

fn initInternal(vec_path: []const u8, lbl_path: []const u8, res_path: []const u8, ivf_path: []const u8) !void {
    const lbl_mem = try mmapRO(lbl_path, 1);
    const vec_mem = try mmapRO(vec_path, 64);
    const res_mem = try mmapRO(res_path, 1);
    const ivf_mem = try mmapRO(ivf_path, 4);

    const n = lbl_mem.len;
    if (vec_mem.len != D * n * @sizeOf(i16)) return error.SizeMismatch;
    if (res_mem.len != D * n) return error.SizeMismatch;
    if ((@intFromPtr(vec_mem.ptr) % 16) != 0) return error.Misaligned;
    if (ivf_mem.len < IVF_MAGIC.len + 5 * @sizeOf(u32)) return error.BadIvfIndex;
    if (!std.mem.eql(u8, ivf_mem[0..IVF_MAGIC.len], IVF_MAGIC)) return error.BadIvfIndex;

    var off: usize = IVF_MAGIC.len;
    const dim = readU32LE(ivf_mem, off);
    off += 4;
    const clusters = readU32LE(ivf_mem, off);
    off += 4;
    const probes = readU32LE(ivf_mem, off);
    off += 4;
    const index_n = readU32LE(ivf_mem, off);
    off += 4;
    _ = readU32LE(ivf_mem, off);
    off += 4;

    if (dim != D or index_n != n or clusters == 0 or clusters > MAX_CLUSTERS) return error.BadIvfIndex;
    if (probes == 0 or probes > MAX_NPROBE) return error.BadIvfIndex;

    const c_usize: usize = @intCast(clusters);
    const centroids_bytes = c_usize * D * @sizeOf(f32);
    const radii_bytes = c_usize * @sizeOf(f32);
    const boundaries_bytes = (c_usize + 1) * @sizeOf(u32);
    if (ivf_mem.len != off + centroids_bytes + radii_bytes + boundaries_bytes) return error.BadIvfIndex;

    n_vecs = n;
    n_clusters = c_usize;
    nprobe = @min(@as(usize, @intCast(probes)), c_usize);
    labels_data = lbl_mem.ptr;
    dims_data = @ptrCast(@alignCast(vec_mem.ptr));
    residuals_data = res_mem.ptr;
    centroids_data = @ptrCast(@alignCast(ivf_mem.ptr + off));
    radii_data = @ptrCast(@alignCast(ivf_mem.ptr + off + centroids_bytes));
    boundaries_data = @ptrCast(@alignCast(ivf_mem.ptr + off + centroids_bytes + radii_bytes));
}

pub export fn vc_init(vec_path: [*:0]const u8, lbl_path: [*:0]const u8, res_path: [*:0]const u8, ivf_path: [*:0]const u8) c_int {
    const v = std.mem.sliceTo(vec_path, 0);
    const l = std.mem.sliceTo(lbl_path, 0);
    const r = std.mem.sliceTo(res_path, 0);
    const i = std.mem.sliceTo(ivf_path, 0);
    initInternal(v, l, r, i) catch |err| {
        const msg = @errorName(err);
        std.debug.print("vc_init failed: {s}\n", .{msg});
        return -1;
    };
    return 0;
}

pub export fn vc_count() usize {
    return n_vecs;
}

inline fn insertCandidate(top_dist: *[TOP_C]f32, top_idx: *[TOP_C]u32, idx: u32, dist: f32) void {
    if (dist < top_dist.*[TOP_C - 1]) {
        var pos: usize = TOP_C - 1;
        while (pos > 0 and top_dist.*[pos - 1] > dist) : (pos -= 1) {
            top_dist.*[pos] = top_dist.*[pos - 1];
            top_idx.*[pos] = top_idx.*[pos - 1];
        }
        top_dist.*[pos] = dist;
        top_idx.*[pos] = idx;
    }
}

inline fn insertRefined(top_dist: *[K]i64, top_idx: *[K]u32, idx: u32, dist: i64) void {
    if (dist < top_dist.*[K - 1]) {
        var pos: usize = K - 1;
        while (pos > 0 and top_dist.*[pos - 1] > dist) : (pos -= 1) {
            top_dist.*[pos] = top_dist.*[pos - 1];
            top_idx.*[pos] = top_idx.*[pos - 1];
        }
        top_dist.*[pos] = dist;
        top_idx.*[pos] = idx;
    }
}

inline fn insertProbe(top_dist: *[MAX_NPROBE]f32, top_idx: *[MAX_NPROBE]u32, limit: usize, idx: u32, dist: f32) void {
    if (dist < top_dist.*[limit - 1]) {
        var pos: usize = limit - 1;
        while (pos > 0 and top_dist.*[pos - 1] > dist) : (pos -= 1) {
            top_dist.*[pos] = top_dist.*[pos - 1];
            top_idx.*[pos] = top_idx.*[pos - 1];
        }
        top_dist.*[pos] = dist;
        top_idx.*[pos] = idx;
    }
}

inline fn lowerBoundSq(centroid_sq_dist: f32, radius: f32) f32 {
    const centroid_dist = @sqrt(centroid_sq_dist);
    if (centroid_dist <= radius) return 0.0;
    const delta = centroid_dist - radius;
    return delta * delta;
}

inline fn scanRangeZig(query: *const [D]f32, start: usize, end: usize, top_dist: *[TOP_C]f32, top_idx: *[TOP_C]u32) void {
    const dims_ptr = dims_data;
    const n = n_vecs;
    const STRIDE = VLEN * 2;

    var offset = start;
    while (offset + STRIDE <= end) : (offset += STRIDE) {
        var dist_0: Vec32 = @splat(@as(f32, 0.0));
        var dist_1: Vec32 = @splat(@as(f32, 0.0));
        var dist_2: Vec32 = @splat(@as(f32, 0.0));
        var dist_3: Vec32 = @splat(@as(f32, 0.0));

        comptime var d: usize = 0;
        inline while (d < D) : (d += 1) {
            const dim_base = dims_ptr + d * n;
            const q: Vec32 = @splat(query.*[d]);

            const p0: *const [AVX2_LANES]i16 = @ptrCast(dim_base + offset);
            const p1: *const [AVX2_LANES]i16 = @ptrCast(dim_base + offset + AVX2_LANES);
            const p2: *const [AVX2_LANES]i16 = @ptrCast(dim_base + offset + VLEN);
            const p3: *const [AVX2_LANES]i16 = @ptrCast(dim_base + offset + VLEN + AVX2_LANES);

            const v0_16: Vec16 = p0.*;
            const v1_16: Vec16 = p1.*;
            const v2_16: Vec16 = p2.*;
            const v3_16: Vec16 = p3.*;
            const v0: Vec32 = @floatFromInt(v0_16);
            const v1: Vec32 = @floatFromInt(v1_16);
            const v2: Vec32 = @floatFromInt(v2_16);
            const v3: Vec32 = @floatFromInt(v3_16);
            const d0 = q - v0;
            const d1 = q - v1;
            const d2 = q - v2;
            const d3 = q - v3;

            dist_0 = @mulAdd(Vec32, d0, d0, dist_0);
            dist_1 = @mulAdd(Vec32, d1, d1, dist_1);
            dist_2 = @mulAdd(Vec32, d2, d2, dist_2);
            dist_3 = @mulAdd(Vec32, d3, d3, dist_3);
        }

        comptime var k: usize = 0;
        inline while (k < AVX2_LANES) : (k += 1) {
            insertCandidate(top_dist, top_idx, @intCast(offset + k), dist_0[k]);
        }
        comptime var k1: usize = 0;
        inline while (k1 < AVX2_LANES) : (k1 += 1) {
            insertCandidate(top_dist, top_idx, @intCast(offset + AVX2_LANES + k1), dist_1[k1]);
        }
        comptime var k2: usize = 0;
        inline while (k2 < AVX2_LANES) : (k2 += 1) {
            insertCandidate(top_dist, top_idx, @intCast(offset + VLEN + k2), dist_2[k2]);
        }
        comptime var k3: usize = 0;
        inline while (k3 < AVX2_LANES) : (k3 += 1) {
            insertCandidate(top_dist, top_idx, @intCast(offset + VLEN + AVX2_LANES + k3), dist_3[k3]);
        }
    }

    while (offset + VLEN <= end) : (offset += VLEN) {
        var dist_lo: Vec32 = @splat(@as(f32, 0.0));
        var dist_hi: Vec32 = @splat(@as(f32, 0.0));

        comptime var d: usize = 0;
        inline while (d < D) : (d += 1) {
            const dim_base = dims_ptr + d * n;
            const lo_ptr: *const [AVX2_LANES]i16 = @ptrCast(dim_base + offset);
            const hi_ptr: *const [AVX2_LANES]i16 = @ptrCast(dim_base + offset + AVX2_LANES);
            const lo_vec16: Vec16 = lo_ptr.*;
            const hi_vec16: Vec16 = hi_ptr.*;
            const lo_vec: Vec32 = @floatFromInt(lo_vec16);
            const hi_vec: Vec32 = @floatFromInt(hi_vec16);
            const q: Vec32 = @splat(query.*[d]);
            const diff_lo = q - lo_vec;
            const diff_hi = q - hi_vec;
            dist_lo = @mulAdd(Vec32, diff_lo, diff_lo, dist_lo);
            dist_hi = @mulAdd(Vec32, diff_hi, diff_hi, dist_hi);
        }

        comptime var k: usize = 0;
        inline while (k < AVX2_LANES) : (k += 1) {
            insertCandidate(top_dist, top_idx, @intCast(offset + k), dist_lo[k]);
        }
        comptime var h: usize = 0;
        inline while (h < AVX2_LANES) : (h += 1) {
            insertCandidate(top_dist, top_idx, @intCast(offset + AVX2_LANES + h), dist_hi[h]);
        }
    }

    while (offset < end) : (offset += 1) {
        var dist: f32 = 0.0;
        var d: usize = 0;
        while (d < D) : (d += 1) {
            const v: f32 = @floatFromInt(dims_ptr[d * n + offset]);
            const diff = query.*[d] - v;
            dist += diff * diff;
        }
        insertCandidate(top_dist, top_idx, @intCast(offset), dist);
    }
}

inline fn scanRangeIspc(query_q16: *const [D]i16, start: usize, end: usize, top_dist: *[TOP_C]f32, top_idx: *[TOP_C]u32) void {
    var out_dists: [TOP_C]f32 = undefined;
    var out_idx: [TOP_C]u32 = undefined;
    var offset = start;
    const n_vectors_i32: c_int = @intCast(n_vecs);

    while (offset < end) {
        const chunk = @min(end - offset, ISPC_DISTANCE_BLOCK);
        const candidate_count = @min(chunk, TOP_C);
        vc_scan_top_q16_ispc(query_q16[0..].ptr, dims_data, n_vectors_i32, @intCast(offset), @intCast(chunk), out_idx[0..].ptr, out_dists[0..].ptr);

        var i: usize = 0;
        while (i < candidate_count) : (i += 1) {
            insertCandidate(top_dist, top_idx, out_idx[i], out_dists[i]);
        }

        offset += chunk;
    }
}

inline fn scanRange(query: *const [D]f32, query_q16: *const [D]i16, start: usize, end: usize, top_dist: *[TOP_C]f32, top_idx: *[TOP_C]u32) void {
    if (comptime build_options.use_ispc) {
        scanRangeIspc(query_q16, start, end, top_dist, top_idx);
    } else {
        scanRangeZig(query, start, end, top_dist, top_idx);
    }
}

inline fn quant16(x: f32) i32 {
    var scaled = @round(x * Q16_SCALE);
    if (scaled < -32767.0) scaled = -32767.0;
    if (scaled > 32767.0) scaled = 32767.0;
    return @intFromFloat(scaled);
}

inline fn quantRefined(x: f32) i32 {
    var scaled = @round(x * REFINE_SCALE);
    if (scaled < @as(f32, @floatFromInt(REFINE_MIN))) scaled = @as(f32, @floatFromInt(REFINE_MIN));
    if (scaled > @as(f32, @floatFromInt(REFINE_MAX))) scaled = @as(f32, @floatFromInt(REFINE_MAX));
    return @intFromFloat(scaled);
}

inline fn refRefined(idx: usize, dim: usize) i32 {
    const base = dim * n_vecs + idx;
    const hi: i32 = @intCast(dims_data[base]);
    const residual: i32 = @intCast(@as(i8, @bitCast(residuals_data[base])));
    return hi * REFINE_STEP + residual;
}

pub export fn vc_query(query_ptr: [*]const f32) c_int {
    if (n_vecs == 0) return 0;

    var query: [D]f32 = undefined;
    var query_q16: [D]i16 = undefined;
    var queryRefined: [D]i32 = undefined;
    {
        var i: usize = 0;
        while (i < D) : (i += 1) {
            const q16 = quant16(query_ptr[i]);
            queryRefined[i] = quantRefined(query_ptr[i]);
            query[i] = @floatFromInt(q16);
            query_q16[i] = @intCast(q16);
        }
    }

    var top_dist = [_]f32{std.math.inf(f32)} ** TOP_C;
    var top_idx = [_]u32{0} ** TOP_C;

    const labels_ptr = labels_data;
    const cluster_count = n_clusters;
    const probe_count = nprobe;
    const centroids_ptr = centroids_data;
    const radii_ptr = radii_data;
    const boundaries_ptr = boundaries_data;

    var probe_dist = [_]f32{std.math.inf(f32)} ** MAX_NPROBE;
    var probe_idx = [_]u32{0} ** MAX_NPROBE;
    var centroid_dist = [_]f32{0.0} ** MAX_CLUSTERS;
    var probed = [_]bool{false} ** MAX_CLUSTERS;

    var c: usize = 0;
    if (comptime build_options.use_ispc) {
        vc_centroid_dists_ispc(query_q16[0..].ptr, centroids_ptr, @intCast(cluster_count), centroid_dist[0..].ptr);
        while (c < cluster_count) : (c += 1) {
            insertProbe(&probe_dist, &probe_idx, probe_count, @intCast(c), centroid_dist[c]);
        }
    } else {
        const cluster_count_aligned = cluster_count & ~@as(usize, 3);
        while (c < cluster_count_aligned) : (c += 4) {
            var d0: f32 = 0.0;
            var d1: f32 = 0.0;
            var d2: f32 = 0.0;
            var d3: f32 = 0.0;
            const b0 = c * D;
            const b1 = (c + 1) * D;
            const b2 = (c + 2) * D;
            const b3 = (c + 3) * D;
            comptime var dd: usize = 0;
            inline while (dd < D) : (dd += 1) {
                const q = query[dd];
                const diff0 = q - centroids_ptr[b0 + dd];
                const diff1 = q - centroids_ptr[b1 + dd];
                const diff2 = q - centroids_ptr[b2 + dd];
                const diff3 = q - centroids_ptr[b3 + dd];
                d0 += diff0 * diff0;
                d1 += diff1 * diff1;
                d2 += diff2 * diff2;
                d3 += diff3 * diff3;
            }
            centroid_dist[c] = d0;
            centroid_dist[c + 1] = d1;
            centroid_dist[c + 2] = d2;
            centroid_dist[c + 3] = d3;
            insertProbe(&probe_dist, &probe_idx, probe_count, @intCast(c), d0);
            insertProbe(&probe_dist, &probe_idx, probe_count, @intCast(c + 1), d1);
            insertProbe(&probe_dist, &probe_idx, probe_count, @intCast(c + 2), d2);
            insertProbe(&probe_dist, &probe_idx, probe_count, @intCast(c + 3), d3);
        }
        while (c < cluster_count) : (c += 1) {
            const base = c * D;
            var dist: f32 = 0.0;
            var d: usize = 0;
            while (d < D) : (d += 1) {
                const diff = query[d] - centroids_ptr[base + d];
                dist += diff * diff;
            }
            centroid_dist[c] = dist;
            insertProbe(&probe_dist, &probe_idx, probe_count, @intCast(c), dist);
        }
    }

    var p: usize = 0;
    while (p < probe_count) : (p += 1) {
        const cluster_id: usize = @intCast(probe_idx[p]);
        probed[cluster_id] = true;
        const start: usize = @intCast(boundaries_ptr[cluster_id]);
        const end: usize = @intCast(boundaries_ptr[cluster_id + 1]);
        scanRange(&query, &query_q16, start, end, &top_dist, &top_idx);
    }

    var expanded = true;
    while (expanded) {
        expanded = false;
        const tau = top_dist[TOP_C - 1];
        c = 0;
        while (c < cluster_count) : (c += 1) {
            if (probed[c]) continue;
            if (lowerBoundSq(centroid_dist[c], radii_ptr[c]) >= tau) continue;
            probed[c] = true;
            const start: usize = @intCast(boundaries_ptr[c]);
            const end: usize = @intCast(boundaries_ptr[c + 1]);
            scanRange(&query, &query_q16, start, end, &top_dist, &top_idx);
            expanded = true;
        }
    }

    if (TOP_C > K and top_dist[K] - top_dist[K - 1] <= COARSE_TIE_GAP) {
        var fraud_count: c_int = 0;
        var k: usize = 0;
        while (k < K) : (k += 1) {
            if (labels_ptr[top_idx[k]] != 0) fraud_count += 1;
        }
        return fraud_count;
    }

    var refined_dist = [_]i64{std.math.maxInt(i64)} ** K;
    var refined_idx = [_]u32{0} ** K;
    var candidate: usize = 0;
    while (candidate < TOP_C and top_dist[candidate] != std.math.inf(f32)) : (candidate += 1) {
        const idx: usize = @intCast(top_idx[candidate]);
        var dist: i64 = 0;
        var d: usize = 0;
        while (d < D) : (d += 1) {
            const diff = @as(i64, queryRefined[d]) - @as(i64, refRefined(idx, d));
            dist += diff * diff;
        }
        insertRefined(&refined_dist, &refined_idx, top_idx[candidate], dist);
    }

    var fraud_count: c_int = 0;
    var k: usize = 0;
    while (k < K) : (k += 1) {
        if (labels_ptr[refined_idx[k]] != 0) fraud_count += 1;
    }
    return fraud_count;
}
