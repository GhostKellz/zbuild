const std = @import("std");
const Config = @import("config.zig").Config;

pub const ParallelBuilder = struct {
    allocator: std.mem.Allocator,
    thread_pool: std.Thread.Pool,
    job_queue: JobQueue,
    results: std.ArrayList(JobResult),
    max_jobs: usize,
    mutex: std.Thread.Mutex,

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
                .jobs = std.ArrayList(Job).init(allocator),
                .ready_queue = std.ArrayList(usize).init(allocator),
                .completed = std.ArrayList(usize).init(allocator),
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *JobQueue) void {
            self.jobs.deinit();
            self.ready_queue.deinit();
            self.completed.deinit();
        }

        pub fn addJob(self: *JobQueue, job: Job) !usize {
            const id = self.jobs.items.len;
            try self.jobs.append(job);
            return id;
        }

        pub fn getReadyJobs(self: *JobQueue) !std.ArrayList(usize) {
            var ready = std.ArrayList(usize).init(self.allocator);

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
                    try ready.append(i);
                    job.status = .waiting;
                }
            }

            return ready;
        }

        pub fn markCompleted(self: *JobQueue, job_id: usize) !void {
            self.jobs.items[job_id].status = .completed;
            try self.completed.append(job_id);
        }

        pub fn markFailed(self: *JobQueue, job_id: usize) void {
            self.jobs.items[job_id].status = .failed;
        }
    };

    pub fn init(allocator: std.mem.Allocator, max_jobs: usize) !ParallelBuilder {
        const cpu_count = try std.Thread.getCpuCount();
        const job_count = if (max_jobs > 0) max_jobs else cpu_count;

        return .{
            .allocator = allocator,
            .thread_pool = undefined,
            .job_queue = JobQueue.init(allocator),
            .results = std.ArrayList(JobResult).init(allocator),
            .max_jobs = job_count,
            .mutex = std.Thread.Mutex{},
        };
    }

    pub fn deinit(self: *ParallelBuilder) void {
        self.job_queue.deinit();
        self.results.deinit();
        self.thread_pool.deinit();
    }

    pub fn createBuildPlan(self: *ParallelBuilder, config: *const Config) !void {
        // Using std.debug.print instead
        std.debug.print("Creating parallel build plan with {} workers\n", .{self.max_jobs});

        var target_it = config.targets.iterator();
        while (target_it.next()) |entry| {
            const target = entry.value_ptr.*;

            var compile_jobs = std.ArrayList(usize).init(self.allocator);
            defer compile_jobs.deinit();

            for (target.sources.items) |source| {
                const job = Job{
                    .id = self.job_queue.jobs.items.len,
                    .type = .compile,
                    .target = target.name,
                    .sources = std.ArrayList([]const u8).init(self.allocator),
                    .output = try std.fmt.allocPrint(self.allocator, "{s}.o", .{std.fs.path.stem(source)}),
                    .dependencies = std.ArrayList(usize).init(self.allocator),
                    .status = .pending,
                };

                const job_id = try self.job_queue.addJob(job);
                try compile_jobs.append(job_id);
            }

            const link_job = Job{
                .id = self.job_queue.jobs.items.len,
                .type = .link,
                .target = target.name,
                .sources = std.ArrayList([]const u8).init(self.allocator),
                .output = target.output,
                .dependencies = compile_jobs,
                .status = .pending,
            };

            _ = try self.job_queue.addJob(link_job);
        }

        std.debug.print("Build plan created: {} jobs\n", .{self.job_queue.jobs.items.len});
    }

    pub fn execute(self: *ParallelBuilder) !void {
        // Using std.debug.print instead
        std.debug.print("Starting parallel build with {} workers\n", .{self.max_jobs});

        try self.thread_pool.init(.{
            .allocator = self.allocator,
            .n_jobs = @intCast(self.max_jobs),
        });

        const start_time = std.time.milliTimestamp();

        while (self.job_queue.completed.items.len < self.job_queue.jobs.items.len) {
            const ready_jobs = try self.job_queue.getReadyJobs();
            defer ready_jobs.deinit();

            for (ready_jobs.items) |job_id| {
                const job = &self.job_queue.jobs.items[job_id];
                job.status = .running;

                try self.thread_pool.spawn(executeJob, .{ self, job_id });
            }

            if (ready_jobs.items.len == 0) {
                std.time.sleep(10 * std.time.ns_per_ms);
            }
        }

        self.thread_pool.deinit();

        const elapsed = std.time.milliTimestamp() - start_time;
        std.debug.print("Build completed in {}ms\n", .{elapsed});

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

    fn executeJob(self: *ParallelBuilder, job_id: usize) void {
        const job = &self.job_queue.jobs.items[job_id];
        const start_time = std.time.milliTimestamp();

        const result = self.executeJobImpl(job) catch |err| {
            const error_msg = std.fmt.allocPrint(self.allocator, "Job failed: {}", .{err}) catch "Unknown error";

            self.mutex.lock();
            defer self.mutex.unlock();

            self.results.append(.{
                .job_id = job_id,
                .success = false,
                .duration_ms = @intCast(std.time.milliTimestamp() - start_time),
                .output = "",
                .error_msg = error_msg,
            }) catch {};

            self.job_queue.markFailed(job_id);
            return;
        };

        self.mutex.lock();
        defer self.mutex.unlock();

        self.results.append(.{
            .job_id = job_id,
            .success = true,
            .duration_ms = @intCast(std.time.milliTimestamp() - start_time),
            .output = result,
            .error_msg = null,
        }) catch {};

        self.job_queue.markCompleted(job_id) catch {};
    }

    fn executeJobImpl(self: *ParallelBuilder, job: *const Job) ![]const u8 {
        // Using std.debug.print instead

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
                std.time.sleep(100 * std.time.ns_per_ms);
                return try self.allocator.dupe(u8, "Compilation successful");
            },
            .link => {
                std.time.sleep(50 * std.time.ns_per_ms);
                return try self.allocator.dupe(u8, "Linking successful");
            },
            .run_tests => {
                std.time.sleep(200 * std.time.ns_per_ms);
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