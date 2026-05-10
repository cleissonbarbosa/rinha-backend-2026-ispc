const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const profiler = @import("profiler.zig");
const posix = std.posix;

const D: usize = 14;
const K: usize = 5;
const TOP_C: usize = 16;
const AVX2_LANES: usize = 8;
const MAX_NPROBE: usize = 24;
const MAX_CLUSTERS: usize = 8192;
const RANGE_SCRATCH: usize = 16384;
const ISPC_TOP_BLOCK: usize = 4096;
const IVF_MAGIC = "RIVF2026";
const Q16_SCALE: f32 = 32767.0;
const REFINE_STEP: i32 = 128;
const REFINE_SCALE: f32 = Q16_SCALE * @as(f32, @floatFromInt(REFINE_STEP));
const REFINE_MIN: i32 = -32767 * REFINE_STEP;
const REFINE_MAX: i32 = 32767 * REFINE_STEP;
const COARSE_TIE_GAP: f32 = 2048.0;
const SIMD_LANES: usize = AVX2_LANES;

const Vec32 = @Vector(AVX2_LANES, f32);
const Vec16 = @Vector(AVX2_LANES, i16);
comptime {
    _ = builtin;
}

var n_vecs: usize = 0;
var n_clusters: usize = 0;
var n_clusters_padded: usize = 0;
var nprobe: usize = 0;
var dims_data: [*]align(64) const i16 = undefined;
var residuals_data: [*]const u8 = undefined;
var labels_data: [*]const u8 = undefined;
var centroids_data: [*]align(4) const f32 = undefined;
var radii_data: [*]align(4) const f32 = undefined;
var boundaries_data: [*]align(4) const u32 = undefined;

var centroids_soa_buf: [MAX_CLUSTERS * D + SIMD_LANES * D]f32 align(64) = undefined;
var centroids_soa_ptr: [*]align(64) const f32 = undefined;

var scratch_centroid_dist: [MAX_CLUSTERS + SIMD_LANES]f32 align(64) = undefined;
var scratch_probed_epoch: [MAX_CLUSTERS]u32 = [_]u32{0} ** MAX_CLUSTERS;
var scratch_epoch: u32 = 0;
var scratch_range_dist: [RANGE_SCRATCH]f32 align(64) = undefined;

extern fn vc_dists_q16_ispc(
    query: [*]const i16,
    dims: [*]const i16,
    n_vectors: c_int,
    start_idx: c_int,
    count: c_int,
    out_dists: [*]f32,
) void;
extern fn vc_scan_top_q16_ispc(
    query: [*]const i16,
    dims: [*]const i16,
    n_vectors: c_int,
    start_idx: c_int,
    count: c_int,
    out_idx: [*]u32,
    out_dists: [*]f32,
) void;
extern fn vc_scan_ranges_top_q16_ispc(
    query: [*]const i16,
    dims: [*]const i16,
    n_vectors: c_int,
    starts: [*]const u32,
    ends: [*]const u32,
    range_count: c_int,
    out_idx: [*]u32,
    out_dists: [*]f32,
) void;
extern fn vc_centroid_dists_soa_ispc(
    query: [*]const i16,
    centroids_soa: [*]const f32,
    n_padded: c_int,
    out_dists: [*]f32,
) void;
extern fn vc_centroid_dists_top_soa_ispc(
    query: [*]const i16,
    centroids_soa: [*]const f32,
    n_padded: c_int,
    probe_count: c_int,
    out_dists: [*]f32,
    out_idx: [*]u32,
    out_probe_dists: [*]f32,
) void;

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

fn buildCentroidsSoA() void {
    const c_count = n_clusters;
    const padded = n_clusters_padded;
    var i: usize = 0;
    while (i < padded * D) : (i += 1) centroids_soa_buf[i] = 0.0;
    var c: usize = 0;
    while (c < c_count) : (c += 1) {
        var d: usize = 0;
        while (d < D) : (d += 1) {
            centroids_soa_buf[d * padded + c] = centroids_data[c * D + d];
        }
    }
    var pc = c_count;
    while (pc < padded) : (pc += 1) {
        var d: usize = 0;
        while (d < D) : (d += 1) {
            centroids_soa_buf[d * padded + pc] = 1.0e9;
        }
    }
    centroids_soa_ptr = @ptrCast(@alignCast(&centroids_soa_buf[0]));
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
    n_clusters_padded = ((c_usize + SIMD_LANES - 1) / SIMD_LANES) * SIMD_LANES;
    nprobe = @min(@as(usize, @intCast(probes)), c_usize);
    labels_data = lbl_mem.ptr;
    dims_data = @ptrCast(@alignCast(vec_mem.ptr));
    residuals_data = res_mem.ptr;
    centroids_data = @ptrCast(@alignCast(ivf_mem.ptr + off));
    radii_data = @ptrCast(@alignCast(ivf_mem.ptr + off + centroids_bytes));
    boundaries_data = @ptrCast(@alignCast(ivf_mem.ptr + off + centroids_bytes + radii_bytes));

    buildCentroidsSoA();
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

inline fn countTopFrauds(labels_ptr: [*]const u8, top_dist: *const [TOP_C]f32, top_idx: *const [TOP_C]u32, limit: usize) c_int {
    var fraud_count: c_int = 0;
    var i: usize = 0;
    while (i < limit and top_dist.*[i] != std.math.inf(f32)) : (i += 1) {
        if (labels_ptr[top_idx.*[i]] != 0) fraud_count += 1;
    }
    return fraud_count;
}

inline fn computeRangeDistsZig(query: *const [D]f32, start: usize, count: usize) void {
    const dims_ptr = dims_data;
    const n = n_vecs;

    {
        const dim_base = dims_ptr + 0 * n + start;
        const q: Vec32 = @splat(query.*[0]);
        var i: usize = 0;
        while (i + AVX2_LANES <= count) : (i += AVX2_LANES) {
            const v_ptr: *const [AVX2_LANES]i16 = @ptrCast(dim_base + i);
            const v_i16: Vec16 = v_ptr.*;
            const v_f32: Vec32 = @floatFromInt(v_i16);
            const diff = q - v_f32;
            const acc_ptr: *Vec32 = @ptrCast(@alignCast(&scratch_range_dist[i]));
            acc_ptr.* = diff * diff;
        }
        // Tail
        while (i < count) : (i += 1) {
            const v: f32 = @floatFromInt(dim_base[i]);
            const diff = query.*[0] - v;
            scratch_range_dist[i] = diff * diff;
        }
    }

    comptime var d: usize = 1;
    inline while (d < D) : (d += 1) {
        const dim_base = dims_ptr + d * n + start;
        const q: Vec32 = @splat(query.*[d]);
        var i: usize = 0;
        while (i + AVX2_LANES <= count) : (i += AVX2_LANES) {
            const v_ptr: *const [AVX2_LANES]i16 = @ptrCast(dim_base + i);
            const v_i16: Vec16 = v_ptr.*;
            const v_f32: Vec32 = @floatFromInt(v_i16);
            const diff = q - v_f32;
            const acc_ptr: *Vec32 = @ptrCast(@alignCast(&scratch_range_dist[i]));
            acc_ptr.* = @mulAdd(Vec32, diff, diff, acc_ptr.*);
        }
        while (i < count) : (i += 1) {
            const v: f32 = @floatFromInt(dim_base[i]);
            const diff = query.*[d] - v;
            scratch_range_dist[i] += diff * diff;
        }
    }
}

inline fn scanRangeIspc(query_q16: *const [D]i16, start: usize, end: usize, top_dist: *[TOP_C]f32, top_idx: *[TOP_C]u32) void {
    const total = end - start;
    if (total == 0) return;

    var out_dists: [TOP_C]f32 = undefined;
    var out_idx: [TOP_C]u32 = undefined;
    var offset = start;
    while (offset < end) {
        const chunk_n = @min(end - offset, ISPC_TOP_BLOCK);
        vc_scan_top_q16_ispc(
            query_q16[0..].ptr,
            dims_data,
            @intCast(n_vecs),
            @intCast(offset),
            @intCast(chunk_n),
            out_idx[0..].ptr,
            out_dists[0..].ptr,
        );
        const candidate_count = @min(chunk_n, TOP_C);
        var i: usize = 0;
        while (i < candidate_count) : (i += 1) {
            insertCandidate(top_dist, top_idx, out_idx[i], out_dists[i]);
        }
        offset += chunk_n;
    }
}

inline fn scanSeedRangesIspc(
    query_q16: *const [D]i16,
    starts: *const [MAX_NPROBE]u32,
    ends: *const [MAX_NPROBE]u32,
    range_count: usize,
    total_vectors: u64,
    top_dist: *[TOP_C]f32,
    top_idx: *[TOP_C]u32,
) void {
    if (range_count == 0 or total_vectors == 0) return;

    var out_dists: [TOP_C]f32 = undefined;
    var out_idx: [TOP_C]u32 = undefined;
    vc_scan_ranges_top_q16_ispc(
        query_q16[0..].ptr,
        dims_data,
        @intCast(n_vecs),
        starts[0..].ptr,
        ends[0..].ptr,
        @intCast(range_count),
        out_idx[0..].ptr,
        out_dists[0..].ptr,
    );

    const candidate_count: usize = @intCast(@min(total_vectors, TOP_C));
    var i: usize = 0;
    while (i < candidate_count) : (i += 1) {
        insertCandidate(top_dist, top_idx, out_idx[i], out_dists[i]);
    }
}

inline fn scanRangeZig(query: *const [D]f32, start: usize, end: usize, top_dist: *[TOP_C]f32, top_idx: *[TOP_C]u32) void {
    const total = end - start;
    if (total == 0) return;

    var offset = start;
    while (offset < end) {
        const chunk_n = @min(end - offset, RANGE_SCRATCH);
        computeRangeDistsZig(query, offset, chunk_n);
        var i: usize = 0;
        while (i < chunk_n) : (i += 1) {
            insertCandidate(top_dist, top_idx, @intCast(offset + i), scratch_range_dist[i]);
        }
        offset += chunk_n;
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

inline fn scanCentroidsSoaZig(query: *const [D]f32, padded: usize, dist_out: [*]f32) void {
    const cs_ptr = centroids_soa_ptr;
    const chunks = padded / AVX2_LANES;
    var chunk: usize = 0;
    while (chunk < chunks) : (chunk += 1) {
        const off = chunk * AVX2_LANES;
        var acc: Vec32 = @splat(@as(f32, 0.0));
        comptime var d: usize = 0;
        inline while (d < D) : (d += 1) {
            const q: Vec32 = @splat(query.*[d]);
            const c_ptr: *const [AVX2_LANES]f32 = @ptrCast(@alignCast(cs_ptr + d * padded + off));
            const c_vec: Vec32 = c_ptr.*;
            const diff = q - c_vec;
            acc = @mulAdd(Vec32, diff, diff, acc);
        }
        const out_ptr: *[AVX2_LANES]f32 = @ptrCast(@alignCast(dist_out + off));
        out_ptr.* = acc;
    }
}

pub export fn vc_query(query_ptr: [*]const f32) c_int {
    if (n_vecs == 0) return 0;

    var query_scope = profiler.Scope.start();
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
    query_scope.lap(.query_quantize);

    var top_dist = [_]f32{std.math.inf(f32)} ** TOP_C;
    var top_idx = [_]u32{0} ** TOP_C;

    const labels_ptr = labels_data;
    const cluster_count = n_clusters;
    const cluster_count_padded = n_clusters_padded;
    const probe_count = nprobe;
    const radii_ptr = radii_data;
    const boundaries_ptr = boundaries_data;

    scratch_epoch +%= 1;
    if (scratch_epoch == 0) {
        var i: usize = 0;
        while (i < MAX_CLUSTERS) : (i += 1) scratch_probed_epoch[i] = 0;
        scratch_epoch = 1;
    }
    const epoch = scratch_epoch;

    var probe_dist = [_]f32{std.math.inf(f32)} ** MAX_NPROBE;
    var probe_idx = [_]u32{0} ** MAX_NPROBE;

    if (comptime build_options.use_ispc) {
        vc_centroid_dists_top_soa_ispc(
            query_q16[0..].ptr,
            centroids_soa_ptr,
            @intCast(cluster_count_padded),
            @intCast(probe_count),
            scratch_centroid_dist[0..].ptr,
            probe_idx[0..].ptr,
            probe_dist[0..].ptr,
        );
    } else {
        scanCentroidsSoaZig(&query, cluster_count_padded, &scratch_centroid_dist);
        var c: usize = 0;
        while (c < cluster_count) : (c += 1) {
            insertProbe(&probe_dist, &probe_idx, probe_count, @intCast(c), scratch_centroid_dist[c]);
        }
    }
    query_scope.lap(.query_centroids);

    var p: usize = 0;
    var seed_vectors: u64 = 0;
    var seed_starts: [MAX_NPROBE]u32 = undefined;
    var seed_ends: [MAX_NPROBE]u32 = undefined;
    while (p < probe_count) : (p += 1) {
        const cluster_id: usize = @intCast(probe_idx[p]);
        scratch_probed_epoch[cluster_id] = epoch;
        const start: usize = @intCast(boundaries_ptr[cluster_id]);
        const end: usize = @intCast(boundaries_ptr[cluster_id + 1]);
        seed_vectors += end - start;
        if (comptime build_options.use_ispc) {
            seed_starts[p] = @intCast(start);
            seed_ends[p] = @intCast(end);
        } else {
            scanRange(&query, &query_q16, start, end, &top_dist, &top_idx);
        }
    }
    if (comptime build_options.use_ispc) {
        scanSeedRangesIspc(&query_q16, &seed_starts, &seed_ends, probe_count, seed_vectors, &top_dist, &top_idx);
    }
    profiler.addCounter(.seed_clusters, probe_count);
    profiler.addCounter(.seed_vectors, seed_vectors);
    query_scope.lap(.query_seed_scan);

    var expanded_clusters: u64 = 0;
    var expanded_vectors: u64 = 0;
    const seed_fraud_count = countTopFrauds(labels_ptr, &top_dist, &top_idx, K);
    const needs_expansion = top_dist[K - 1] == std.math.inf(f32) or (seed_fraud_count != 0 and seed_fraud_count != K);
    if (needs_expansion) {
        var expanded = true;
        while (expanded) {
            expanded = false;
            const tau = top_dist[TOP_C - 1];
            var c: usize = 0;
            while (c < cluster_count) : (c += 1) {
                if (scratch_probed_epoch[c] == epoch) continue;
                if (lowerBoundSq(scratch_centroid_dist[c], radii_ptr[c]) >= tau) continue;
                scratch_probed_epoch[c] = epoch;
                const start: usize = @intCast(boundaries_ptr[c]);
                const end: usize = @intCast(boundaries_ptr[c + 1]);
                expanded_clusters += 1;
                expanded_vectors += end - start;
                scanRange(&query, &query_q16, start, end, &top_dist, &top_idx);
                expanded = true;
            }
        }
    }
    profiler.addCounter(.expanded_clusters, expanded_clusters);
    profiler.addCounter(.expanded_vectors, expanded_vectors);
    query_scope.lap(.query_expansion);

    if (TOP_C > K and top_dist[K] - top_dist[K - 1] <= COARSE_TIE_GAP) {
        var fraud_count: c_int = 0;
        var k: usize = 0;
        while (k < K) : (k += 1) {
            if (labels_ptr[top_idx[k]] != 0) fraud_count += 1;
        }
        profiler.incrementCounter(.coarse_shortcuts);
        query_scope.lap(.query_vote);
        query_scope.finish(.query_total);
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
    profiler.addCounter(.refined_candidates, candidate);
    query_scope.lap(.query_refine);

    var fraud_count: c_int = 0;
    var k: usize = 0;
    while (k < K) : (k += 1) {
        if (labels_ptr[refined_idx[k]] != 0) fraud_count += 1;
    }
    query_scope.lap(.query_vote);
    query_scope.finish(.query_total);
    return fraud_count;
}
