const std = @import("std");
const build_options = @import("build_options");

const AtomicU64 = std.atomic.Value(u64);
pub const compiled_in = build_options.enable_profiler;

pub const Stage = enum(u8) {
    fraud_total,
    read_request,
    find_body,
    parse_json,
    vectorize,
    core_query,
    write_response,
    query_total,
    query_quantize,
    query_centroids,
    query_seed_scan,
    query_expansion,
    query_refine,
    query_vote,
};

pub const Counter = enum(u8) {
    seed_clusters,
    seed_vectors,
    expanded_clusters,
    expanded_vectors,
    refined_candidates,
    coarse_shortcuts,
};

const stage_count = @typeInfo(Stage).Enum.fields.len;
const counter_count = @typeInfo(Counter).Enum.fields.len;

var enabled_flag = false;
var log_every: u64 = 10_000;
var instance_label: []const u8 = "unknown";

var stage_total_ns = [_]AtomicU64{AtomicU64.init(0)} ** stage_count;
var stage_hits = [_]AtomicU64{AtomicU64.init(0)} ** stage_count;
var counter_totals = [_]AtomicU64{AtomicU64.init(0)} ** counter_count;

const RealScope = struct {
    timer: ?std.time.Timer = null,
    last_ns: u64 = 0,

    pub fn start() RealScope {
        if (!enabled_flag) return .{};

        return .{
            .timer = std.time.Timer.start() catch null,
            .last_ns = 0,
        };
    }

    pub fn lap(self: *Scope, stage: Stage) void {
        if (self.timer) |*timer| {
            const now = timer.read();
            const elapsed = now - self.last_ns;
            self.last_ns = now;
            _ = recordStageDuration(stage, elapsed);
        }
    }

    pub fn finish(self: *Scope, stage: Stage) void {
        if (self.timer) |*timer| {
            const total = timer.read();
            const count = recordStageDuration(stage, total);
            if (stage == .fraud_total) maybeReport(count);
        }
    }
};

const NoopScope = struct {
    pub fn start() NoopScope {
        return .{};
    }

    pub fn lap(self: *NoopScope, stage: Stage) void {
        _ = self;
        _ = stage;
    }

    pub fn finish(self: *NoopScope, stage: Stage) void {
        _ = self;
        _ = stage;
    }
};

pub const Scope = if (compiled_in) RealScope else NoopScope;

pub fn initFromEnv() void {
    if (!compiled_in) return;

    instance_label = std.posix.getenv("INSTANCE") orelse "unknown";

    const raw_enabled = std.posix.getenv("PROFILE") orelse "0";
    enabled_flag = parseBool(raw_enabled);
    if (!enabled_flag) return;

    const raw_log_every = std.posix.getenv("PROFILE_LOG_EVERY") orelse "10000";
    log_every = std.fmt.parseInt(u64, raw_log_every, 10) catch 10_000;
    if (log_every == 0) log_every = 10_000;

    std.debug.print("Profiler enabled for instance={s}, log_every={d}\n", .{ instance_label, log_every });
}

pub fn enabled() bool {
    return compiled_in and enabled_flag;
}

pub fn addCounter(counter: Counter, value: u64) void {
    if (!compiled_in) return;
    if (!enabled_flag) return;
    _ = counter_totals[@intFromEnum(counter)].fetchAdd(value, .monotonic);
}

pub fn incrementCounter(counter: Counter) void {
    addCounter(counter, 1);
}

fn parseBool(value: []const u8) bool {
    if (value.len == 0) return false;
    if (std.mem.eql(u8, value, "1")) return true;
    if (std.ascii.eqlIgnoreCase(value, "true")) return true;
    if (std.ascii.eqlIgnoreCase(value, "yes")) return true;
    if (std.ascii.eqlIgnoreCase(value, "on")) return true;
    return false;
}

fn recordStageDuration(stage: Stage, elapsed_ns: u64) u64 {
    if (!compiled_in) return 0;
    if (!enabled_flag) return 0;

    const idx = @intFromEnum(stage);
    _ = stage_total_ns[idx].fetchAdd(elapsed_ns, .monotonic);
    return stage_hits[idx].fetchAdd(1, .monotonic) + 1;
}

fn maybeReport(request_count: u64) void {
    if (!enabled_flag or request_count == 0 or request_count % log_every != 0) return;

    const query_count = loadStageHits(.query_total);
    const total_avg = avgMicros(.fraud_total, request_count);
    const read_avg = avgMicros(.read_request, request_count);
    const body_avg = avgMicros(.find_body, request_count);
    const parse_avg = avgMicros(.parse_json, request_count);
    const vectorize_avg = avgMicros(.vectorize, request_count);
    const core_query_avg = avgMicros(.core_query, request_count);
    const write_avg = avgMicros(.write_response, request_count);

    std.debug.print(
        "PROFILE instance={s} requests={d} avg_us total={d:.2} read={d:.2} body={d:.2} parse={d:.2} vectorize={d:.2} query={d:.2} write={d:.2}\n",
        .{ instance_label, request_count, total_avg, read_avg, body_avg, parse_avg, vectorize_avg, core_query_avg, write_avg },
    );

    if (query_count == 0) return;

    std.debug.print(
        "PROFILE instance={s} query_avg_us total={d:.2} quantize={d:.2} centroids={d:.2} seed_scan={d:.2} expansion={d:.2} refine={d:.2} vote={d:.2} avg_counts seed_clusters={d:.2} seed_vectors={d:.2} expanded_clusters={d:.2} expanded_vectors={d:.2} refined_candidates={d:.2} shortcut_rate={d:.2}%\n",
        .{
            instance_label,
            avgMicros(.query_total, query_count),
            avgMicros(.query_quantize, query_count),
            avgMicros(.query_centroids, query_count),
            avgMicros(.query_seed_scan, query_count),
            avgMicros(.query_expansion, query_count),
            avgMicros(.query_refine, query_count),
            avgMicros(.query_vote, query_count),
            avgCounter(.seed_clusters, query_count),
            avgCounter(.seed_vectors, query_count),
            avgCounter(.expanded_clusters, query_count),
            avgCounter(.expanded_vectors, query_count),
            avgCounter(.refined_candidates, query_count),
            pctCounter(.coarse_shortcuts, query_count),
        },
    );
}

fn loadStageHits(stage: Stage) u64 {
    return stage_hits[@intFromEnum(stage)].load(.monotonic);
}

fn avgMicros(stage: Stage, base_count: u64) f64 {
    if (base_count == 0) return 0.0;
    const total_ns = stage_total_ns[@intFromEnum(stage)].load(.monotonic);
    return @as(f64, @floatFromInt(total_ns)) / @as(f64, @floatFromInt(base_count)) / 1000.0;
}

fn avgCounter(counter: Counter, base_count: u64) f64 {
    if (base_count == 0) return 0.0;
    const total = counter_totals[@intFromEnum(counter)].load(.monotonic);
    return @as(f64, @floatFromInt(total)) / @as(f64, @floatFromInt(base_count));
}

fn pctCounter(counter: Counter, base_count: u64) f64 {
    return avgCounter(counter, base_count) * 100.0;
}
