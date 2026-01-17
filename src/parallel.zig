const std = @import("std");
const Config = @import("config.zig").Config;

pub const ParallelBuilder = struct {
    allocator: std.mem.Allocator,
    job_queue: JobQueue,
    results: std.ArrayList(JobResult),
    max_jobs: usize,
    mutex: std.Thread.Mutex,
    threads: std.ArrayList(std.Thread),
    active_jobs: std.atomic.Value(usize),
    should_stop: std.atomic.Value(bool),
    io: ?std.Io,

    pub const Job = struct {
        id: usize,
        type: JobType,
        target: []const u8,
        sources: std.ArrayList([]const u8),
        output: []const u8,
        dependencies: std.ArrayList(usize),
        status: JobStatus,
    };

    pub const JobType = enum {
        compile,
        link,
        archive,
        run_tests,
        custom,
    };

    pub const JobStatus = enum {
        pending,
        waiting,
        running,
        completed,
        failed,
        skipped,
    };

    pub const JobResult = struct {
        job_id: usize,
        success: bool,
        duration_ms: u64,
        output: []const u8,
        error_msg: ?[]const u8,
    };

    pub const JobQueue = struct {
        jobs: std.ArrayList(Job),
        ready_queue: std.ArrayList(usize),
        completed: std.ArrayList(usize),
        allocator: std.mem.Allocator,

        pub fn init(allocator: std.mem.Allocator) JobQueue {
            return .{
                .jobs = .empty,
                .ready_queue = .empty,
                .completed = .empty,
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *JobQueue) void {
            self.jobs.deinit(self.allocator);
            self.ready_queue.deinit(self.allocator);
            self.completed.deinit(self.allocator);
        }

        pub fn addJob(self: *JobQueue, job: Job) !usize {
            const id = self.jobs.items.len;
            try self.jobs.append(self.allocator, job);
            return id;
        }

        pub fn getReadyJobs(self: *JobQueue) !std.ArrayList(usize) {
            var ready: std.ArrayList(usize) = .empty;

            for (self.jobs.items, 0..) |*job, i| {
                if (job.status != .pending) continue;

                var all_deps_complete = true;
                for (job.dependencies.items) |dep_id| {
                    const dep_job = &self.jobs.items[dep_id];
                    if (dep_job.status != .completed) {
                        all_deps_complete = false;
                        break;
                    }
                }

                if (all_deps_complete) {
                    try ready.append(self.allocator, i);
                    job.status = .waiting;
                }
            }

            return ready;
        }

        pub fn markCompleted(self: *JobQueue, job_id: usize) !void {
            self.jobs.items[job_id].status = .completed;
            try self.completed.append(self.allocator, job_id);
        }

        pub fn markFailed(self: *JobQueue, job_id: usize) void {
            self.jobs.items[job_id].status = .failed;
        }
    };

    pub fn init(allocator: std.mem.Allocator, max_jobs: usize, io: std.Io) !ParallelBuilder {
        const cpu_count = try std.Thread.getCpuCount();
        const job_count = if (max_jobs > 0) max_jobs else cpu_count;

        return .{
            .allocator = allocator,
            .job_queue = JobQueue.init(allocator),
            .results = .empty,
            .max_jobs = job_count,
            .mutex = .{},
            .threads = .empty,
            .active_jobs = std.atomic.Value(usize).init(0),
            .should_stop = std.atomic.Value(bool).init(false),
            .io = io,
        };
    }

    /// Initialize without Io interface - for use cases like graph visualization
    /// that don't need actual I/O operations
    pub fn initWithoutIo(allocator: std.mem.Allocator, max_jobs: usize) !ParallelBuilder {
        const cpu_count = try std.Thread.getCpuCount();
        const job_count = if (max_jobs > 0) max_jobs else cpu_count;

        return .{
            .allocator = allocator,
            .job_queue = JobQueue.init(allocator),
            .results = .empty,
            .max_jobs = job_count,
            .mutex = .{},
            .threads = .empty,
            .active_jobs = std.atomic.Value(usize).init(0),
            .should_stop = std.atomic.Value(bool).init(false),
            .io = null,
        };
    }

    pub fn deinit(self: *ParallelBuilder) void {
        self.job_queue.deinit();
        self.results.deinit(self.allocator);
        self.threads.deinit(self.allocator);
    }

    pub fn createBuildPlan(self: *ParallelBuilder, config: *const Config) !void {
        std.debug.print("Creating parallel build plan with {} workers\n", .{self.max_jobs});

        var target_it = config.targets.iterator();
        while (target_it.next()) |entry| {
            const target = entry.value_ptr.*;

            var compile_jobs: std.ArrayList(usize) = .empty;
            defer compile_jobs.deinit(self.allocator);

            for (target.sources.items) |source| {
                const job = Job{
                    .id = self.job_queue.jobs.items.len,
                    .type = .compile,
                    .target = target.name,
                    .sources = .empty,
                    .output = try std.fmt.allocPrint(self.allocator, "{s}.o", .{std.fs.path.stem(source)}),
                    .dependencies = .empty,
                    .status = .pending,
                };

                const job_id = try self.job_queue.addJob(job);
                try compile_jobs.append(self.allocator, job_id);
            }

            var link_deps: std.ArrayList(usize) = .empty;
            for (compile_jobs.items) |job_id| {
                try link_deps.append(self.allocator, job_id);
            }

            const link_job = Job{
                .id = self.job_queue.jobs.items.len,
                .type = .link,
                .target = target.name,
                .sources = .empty,
                .output = target.output,
                .dependencies = link_deps,
                .status = .pending,
            };

            _ = try self.job_queue.addJob(link_job);
        }

        std.debug.print("Build plan created: {} jobs\n", .{self.job_queue.jobs.items.len});
    }

    pub fn execute(self: *ParallelBuilder) !void {
        std.debug.print("Starting parallel build with {} workers\n", .{self.max_jobs});

        const start_time = std.time.Instant.now() catch std.time.Instant{ .timestamp = std.posix.timespec{ .sec = 0, .nsec = 0 } };

        while (self.job_queue.completed.items.len < self.job_queue.jobs.items.len) {
            self.mutex.lock();
            var ready_jobs = try self.job_queue.getReadyJobs();
            self.mutex.unlock();
            defer ready_jobs.deinit(self.allocator);

            for (ready_jobs.items) |job_id| {
                // Wait if we've hit max parallelism
                while (self.active_jobs.load(.acquire) >= self.max_jobs) {
                    self.sleepMs(1);
                }

                self.mutex.lock();
                self.job_queue.jobs.items[job_id].status = .running;
                self.mutex.unlock();

                _ = self.active_jobs.fetchAdd(1, .acq_rel);

                const thread = try std.Thread.spawn(.{}, executeJobThread, .{ self, job_id });
                try self.threads.append(self.allocator, thread);
            }

            if (ready_jobs.items.len == 0) {
                self.sleepMs(10);
            }
        }

        // Wait for all threads to complete
        for (self.threads.items) |thread| {
            thread.join();
        }

        const end_time = std.time.Instant.now() catch std.time.Instant{ .timestamp = std.posix.timespec{ .sec = 0, .nsec = 0 } };
        const elapsed_ns = end_time.since(start_time);
        const elapsed_ms = elapsed_ns / std.time.ns_per_ms;
        std.debug.print("Build completed in {}ms\n", .{elapsed_ms});

        var failed_count: usize = 0;
        for (self.results.items) |result| {
            if (!result.success) {
                failed_count += 1;
                if (result.error_msg) |msg| {
                    std.debug.print("Job {} failed: {s}\n", .{ result.job_id, msg });
                }
            }
        }

        if (failed_count > 0) {
            std.debug.print("{} jobs failed\n", .{failed_count});
            return error.BuildFailed;
        }
    }

    /// Helper function to sleep using Io interface if available
    fn sleepMs(self: *ParallelBuilder, ms: u64) void {
        if (self.io) |io| {
            std.Io.sleep(io, .fromMilliseconds(@intCast(ms)), .awake) catch {};
        }
        // If no Io interface available, busy-wait is handled by the caller
    }

    fn executeJobThread(self: *ParallelBuilder, job_id: usize) void {
        defer _ = self.active_jobs.fetchSub(1, .acq_rel);

        self.mutex.lock();
        const job = &self.job_queue.jobs.items[job_id];
        self.mutex.unlock();

        const start_time = std.time.Instant.now() catch std.time.Instant{ .timestamp = std.posix.timespec{ .sec = 0, .nsec = 0 } };

        const result = self.executeJobImpl(job) catch |err| {
            const error_msg = std.fmt.allocPrint(self.allocator, "Job failed: {}", .{err}) catch "Unknown error";

            const end_time = std.time.Instant.now() catch std.time.Instant{ .timestamp = std.posix.timespec{ .sec = 0, .nsec = 0 } };
            const duration_ns = end_time.since(start_time);

            self.mutex.lock();
            defer self.mutex.unlock();

            self.results.append(self.allocator, .{
                .job_id = job_id,
                .success = false,
                .duration_ms = duration_ns / std.time.ns_per_ms,
                .output = "",
                .error_msg = error_msg,
            }) catch {};

            self.job_queue.markFailed(job_id);
            return;
        };

        const end_time = std.time.Instant.now() catch std.time.Instant{ .timestamp = std.posix.timespec{ .sec = 0, .nsec = 0 } };
        const duration_ns = end_time.since(start_time);

        self.mutex.lock();
        defer self.mutex.unlock();

        self.results.append(self.allocator, .{
            .job_id = job_id,
            .success = true,
            .duration_ms = duration_ns / std.time.ns_per_ms,
            .output = result,
            .error_msg = null,
        }) catch {};

        self.job_queue.markCompleted(job_id) catch {};
    }

    fn executeJobImpl(self: *ParallelBuilder, job: *const Job) ![]const u8 {
        self.mutex.lock();
        std.debug.print("[{}/{}] {} {s}\n", .{
            self.job_queue.completed.items.len + 1,
            self.job_queue.jobs.items.len,
            job.type,
            job.output,
        });
        self.mutex.unlock();

        switch (job.type) {
            .compile => {
                self.sleepMs(100);
                return try self.allocator.dupe(u8, "Compilation successful");
            },
            .link => {
                self.sleepMs(50);
                return try self.allocator.dupe(u8, "Linking successful");
            },
            .run_tests => {
                self.sleepMs(200);
                return try self.allocator.dupe(u8, "Tests passed");
            },
            else => {
                return try self.allocator.dupe(u8, "Job completed");
            },
        }
    }

    pub fn visualizeBuildGraph(self: *const ParallelBuilder, writer: anytype) !void {
        try writer.print("digraph BuildGraph {{\n", .{});
        try writer.print("  rankdir=LR;\n", .{});
        try writer.print("  node [shape=box];\n\n", .{});

        for (self.job_queue.jobs.items) |job| {
            const color = switch (job.status) {
                .completed => "green",
                .failed => "red",
                .running => "yellow",
                .waiting => "orange",
                else => "gray",
            };

            try writer.print("  job_{} [label=\"{s}\\n{s}\", color={s}];\n", .{
                job.id,
                @tagName(job.type),
                job.output,
                color,
            });
        }

        try writer.print("\n", .{});

        for (self.job_queue.jobs.items) |job| {
            for (job.dependencies.items) |dep_id| {
                try writer.print("  job_{} -> job_{};\n", .{ dep_id, job.id });
            }
        }

        try writer.print("}}\n", .{});
    }

    pub fn getStatistics(self: *const ParallelBuilder) Statistics {
        var total_duration: u64 = 0;
        var min_duration: u64 = std.math.maxInt(u64);
        var max_duration: u64 = 0;
        var failed_count: usize = 0;

        for (self.results.items) |result| {
            total_duration += result.duration_ms;
            min_duration = @min(min_duration, result.duration_ms);
            max_duration = @max(max_duration, result.duration_ms);
            if (!result.success) failed_count += 1;
        }

        const avg_duration = if (self.results.items.len > 0)
            total_duration / self.results.items.len
        else
            0;

        return .{
            .total_jobs = self.job_queue.jobs.items.len,
            .completed_jobs = self.job_queue.completed.items.len,
            .failed_jobs = failed_count,
            .avg_duration_ms = avg_duration,
            .min_duration_ms = if (min_duration == std.math.maxInt(u64)) 0 else min_duration,
            .max_duration_ms = max_duration,
            .parallelism = self.max_jobs,
        };
    }

    pub const Statistics = struct {
        total_jobs: usize,
        completed_jobs: usize,
        failed_jobs: usize,
        avg_duration_ms: u64,
        min_duration_ms: u64,
        max_duration_ms: u64,
        parallelism: usize,
    };
};
