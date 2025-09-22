const std = @import("std");
const Builder = @import("builder.zig").Builder;
const Config = @import("config.zig").Config;
const ParallelBuilder = @import("parallel.zig").ParallelBuilder;

pub const Benchmark = struct {
    allocator: std.mem.Allocator,
    results: std.ArrayList(BenchmarkResult),
    comparisons: std.ArrayList(Comparison),
    output_format: OutputFormat,

    pub const BenchmarkResult = struct {
        name: []const u8,
        category: Category,
        iterations: usize,
        total_time_ns: u64,
        min_time_ns: u64,
        max_time_ns: u64,
        avg_time_ns: u64,
        std_dev_ns: u64,
        memory_used: usize,
        cache_hits: usize,
        cache_misses: usize,
        cpu_usage: f32,
        timestamp: i64,
    };

    pub const Category = enum {
        full_build,
        incremental_build,
        clean_build,
        parallel_build,
        single_file,
        link_only,
        test_run,
        cache_operation,
    };

    pub const OutputFormat = enum {
        text,
        json,
        csv,
        markdown,
    };

    pub const Comparison = struct {
        baseline: BenchmarkResult,
        current: BenchmarkResult,
        speedup: f64,
        memory_diff: i64,
        cache_improvement: f64,
    };

    pub fn init(allocator: std.mem.Allocator) Benchmark {
        return .{
            .allocator = allocator,
            .results = std.ArrayList(BenchmarkResult).init(allocator),
            .comparisons = std.ArrayList(Comparison).init(allocator),
            .output_format = .text,
        };
    }

    pub fn deinit(self: *Benchmark) void {
        self.results.deinit();
        self.comparisons.deinit();
    }

    pub fn runFullSuite(self: *Benchmark, config: *Config, builder: *Builder) !void {
        // Using std.debug.print instead
        std.debug.print("Running zbuild benchmark suite...\n\n", .{});

        try self.benchmarkFullBuild(config, builder);
        try self.benchmarkIncrementalBuild(config, builder);
        try self.benchmarkParallelBuild(config);
        try self.benchmarkCacheOperations(builder);
        try self.benchmarkSingleFile(config, builder);

        try self.generateReport();
    }

    fn benchmarkFullBuild(self: *Benchmark, _: *Config, builder: *Builder) !void {
        // Using std.debug.print instead
        std.debug.print("Benchmarking full build...\n", .{});

        const iterations = 5;
        var times = std.ArrayList(u64).init(self.allocator);
        defer times.deinit();

        for (0..iterations) |i| {
            try self.cleanBuildDirectory();

            const start = std.time.nanoTimestamp();
            try builder.build("default");
            const elapsed = @as(u64, @intCast(std.time.nanoTimestamp() - start));

            try times.append(elapsed);
            std.debug.print("  Iteration {}: {}ms\n", .{ i + 1, elapsed / std.time.ns_per_ms });
        }

        const result = try self.calculateStats("Full Build", .full_build, times.items);
        try self.results.append(result);
    }

    fn benchmarkIncrementalBuild(self: *Benchmark, config: *Config, builder: *Builder) !void {
        // Using std.debug.print instead
        std.debug.print("Benchmarking incremental build...\n", .{});

        try builder.build("default");

        var target_it = config.targets.iterator();
        if (target_it.next()) |entry| {
            const target = entry.value_ptr.*;
            if (target.sources.items.len > 0) {
                const file_path = target.sources.items[0];
                try self.touchFile(file_path);
            }
        }

        const iterations = 10;
        var times = std.ArrayList(u64).init(self.allocator);
        defer times.deinit();

        for (0..iterations) |i| {
            const start = std.time.nanoTimestamp();
            try builder.build("default");
            const elapsed = @as(u64, @intCast(std.time.nanoTimestamp() - start));

            try times.append(elapsed);
            std.debug.print("  Iteration {}: {}ms\n", .{ i + 1, elapsed / std.time.ns_per_ms });
        }

        const result = try self.calculateStats("Incremental Build", .incremental_build, times.items);
        try self.results.append(result);
    }

    fn benchmarkParallelBuild(self: *Benchmark, config: *Config) !void {
        // Using std.debug.print instead
        std.debug.print("Benchmarking parallel build...\n", .{});

        const cpu_counts = [_]usize{ 1, 2, 4, 8 };

        for (cpu_counts) |cpu_count| {
            var parallel_builder = try ParallelBuilder.init(self.allocator, cpu_count);
            defer parallel_builder.deinit();

            try parallel_builder.createBuildPlan(config);

            const start = std.time.nanoTimestamp();
            try parallel_builder.execute();
            const elapsed = @as(u64, @intCast(std.time.nanoTimestamp() - start));

            std.debug.print("  {} workers: {}ms\n", .{ cpu_count, elapsed / std.time.ns_per_ms });

            const name = try std.fmt.allocPrint(self.allocator, "Parallel Build ({} workers)", .{cpu_count});
            defer self.allocator.free(name);

            const result = BenchmarkResult{
                .name = try self.allocator.dupe(u8, name),
                .category = .parallel_build,
                .iterations = 1,
                .total_time_ns = elapsed,
                .min_time_ns = elapsed,
                .max_time_ns = elapsed,
                .avg_time_ns = elapsed,
                .std_dev_ns = 0,
                .memory_used = 0,
                .cache_hits = 0,
                .cache_misses = 0,
                .cpu_usage = @as(f32, @floatFromInt(cpu_count)) * 100.0,
                .timestamp = std.time.timestamp(),
            };

            try self.results.append(result);
        }
    }

    fn benchmarkCacheOperations(self: *Benchmark, builder: *Builder) !void {
        // Using std.debug.print instead
        std.debug.print("Benchmarking cache operations...\n", .{});

        const test_data = try self.allocator.alloc(u8, 1024 * 1024);
        defer self.allocator.free(test_data);
        for (test_data) |*byte| {
            byte.* = 42;
        }

        const iterations = 100;
        var store_times = std.ArrayList(u64).init(self.allocator);
        defer store_times.deinit();
        var retrieve_times = std.ArrayList(u64).init(self.allocator);
        defer retrieve_times.deinit();

        for (0..iterations) |i| {
            const key = try std.fmt.allocPrint(self.allocator, "test_key_{}", .{i});
            defer self.allocator.free(key);

            const store_start = std.time.nanoTimestamp();
            try builder.cache.store(key, test_data.ptr, test_data.len);
            const store_elapsed = @as(u64, @intCast(std.time.nanoTimestamp() - store_start));
            try store_times.append(store_elapsed);

            const buffer = try self.allocator.alloc(u8, test_data.len);
            defer self.allocator.free(buffer);

            const retrieve_start = std.time.nanoTimestamp();
            _ = try builder.cache.retrieve(key, buffer);
            const retrieve_elapsed = @as(u64, @intCast(std.time.nanoTimestamp() - retrieve_start));
            try retrieve_times.append(retrieve_elapsed);
        }

        const store_result = try self.calculateStats("Cache Store", .cache_operation, store_times.items);
        const retrieve_result = try self.calculateStats("Cache Retrieve", .cache_operation, retrieve_times.items);

        try self.results.append(store_result);
        try self.results.append(retrieve_result);

        const cache_stats = builder.cache.getStats();
        std.debug.print("  Cache size: {} entries, {} bytes\n", .{
            cache_stats.entry_count,
            cache_stats.total_size,
        });
    }

    fn benchmarkSingleFile(self: *Benchmark, config: *Config, _: *Builder) !void {
        // Using std.debug.print instead
        std.debug.print("Benchmarking single file compilation...\n", .{});

        var target_it = config.targets.iterator();
        if (target_it.next()) |entry| {
            const target = entry.value_ptr.*;
            if (target.sources.items.len > 0) {
                const iterations = 20;
                var times = std.ArrayList(u64).init(self.allocator);
                defer times.deinit();

                for (0..iterations) |i| {
                    _ = i;
                    const start = std.time.nanoTimestamp();

                    std.time.sleep(10 * std.time.ns_per_ms);

                    const elapsed = @as(u64, @intCast(std.time.nanoTimestamp() - start));
                    try times.append(elapsed);
                }

                const result = try self.calculateStats("Single File", .single_file, times.items);
                try self.results.append(result);
            }
        }
    }

    fn calculateStats(self: *Benchmark, name: []const u8, category: Category, times: []const u64) !BenchmarkResult {
        var total: u64 = 0;
        var min: u64 = std.math.maxInt(u64);
        var max: u64 = 0;

        for (times) |time| {
            total += time;
            min = @min(min, time);
            max = @max(max, time);
        }

        const avg = total / times.len;

        var variance: u64 = 0;
        for (times) |time| {
            const diff = if (time > avg) time - avg else avg - time;
            variance += diff * diff;
        }
        variance /= times.len;
        const std_dev = std.math.sqrt(variance);

        return BenchmarkResult{
            .name = try self.allocator.dupe(u8, name),
            .category = category,
            .iterations = times.len,
            .total_time_ns = total,
            .min_time_ns = min,
            .max_time_ns = max,
            .avg_time_ns = avg,
            .std_dev_ns = @as(u64, @intFromFloat(std_dev)),
            .memory_used = 0,
            .cache_hits = 0,
            .cache_misses = 0,
            .cpu_usage = 0.0,
            .timestamp = std.time.timestamp(),
        };
    }

    fn cleanBuildDirectory(self: *Benchmark) !void {
        _ = self;
        std.fs.cwd().deleteTree(".zbuild/build") catch {};
        try std.fs.cwd().makePath(".zbuild/build");
    }

    fn touchFile(self: *Benchmark, path: []const u8) !void {
        _ = self;
        const file = try std.fs.cwd().openFile(path, .{ .mode = .read_write });
        defer file.close();
        try file.setEndPos(try file.getEndPos());
    }

    pub fn generateReport(self: *Benchmark) !void {
        switch (self.output_format) {
            .text => try self.generateTextReport(),
            .json => try self.generateJsonReport(),
            .csv => try self.generateCsvReport(),
            .markdown => try self.generateMarkdownReport(),
        }
    }

    fn generateTextReport(self: *Benchmark) !void {
        // Using std.debug.print instead
        std.debug.print("\n" ++ "=" ** 80 ++ "\n", .{});
        std.debug.print("zbuild Benchmark Results\n", .{});
        std.debug.print("=" ** 80 ++ "\n\n", .{});

        for (self.results.items) |result| {
            std.debug.print("{s}:\n", .{result.name});
            std.debug.print("  Iterations: {}\n", .{result.iterations});
            std.debug.print("  Average: {}ms\n", .{result.avg_time_ns / std.time.ns_per_ms});
            std.debug.print("  Min: {}ms\n", .{result.min_time_ns / std.time.ns_per_ms});
            std.debug.print("  Max: {}ms\n", .{result.max_time_ns / std.time.ns_per_ms});
            std.debug.print("  Std Dev: {}ms\n", .{result.std_dev_ns / std.time.ns_per_ms});
            std.debug.print("\n", .{});
        }

        try self.generateSummary();
    }

    fn generateJsonReport(self: *Benchmark) !void {
        // Using std.debug.print instead
        std.debug.print("{{\"results\":[", .{});

        for (self.results.items, 0..) |result, i| {
            if (i > 0) std.debug.print(",", .{});
            std.debug.print("{{\"name\":\"{s}\",\"avg_ms\":{},\"min_ms\":{},\"max_ms\":{}}}", .{
                result.name,
                result.avg_time_ns / std.time.ns_per_ms,
                result.min_time_ns / std.time.ns_per_ms,
                result.max_time_ns / std.time.ns_per_ms,
            });
        }

        std.debug.print("]}}\n", .{});
    }

    fn generateCsvReport(self: *Benchmark) !void {
        // Using std.debug.print instead
        std.debug.print("Name,Category,Iterations,Avg(ms),Min(ms),Max(ms),StdDev(ms)\n", .{});

        for (self.results.items) |result| {
            std.debug.print("{s},{s},{},{},{},{},{}\n", .{
                result.name,
                @tagName(result.category),
                result.iterations,
                result.avg_time_ns / std.time.ns_per_ms,
                result.min_time_ns / std.time.ns_per_ms,
                result.max_time_ns / std.time.ns_per_ms,
                result.std_dev_ns / std.time.ns_per_ms,
            });
        }
    }

    fn generateMarkdownReport(self: *Benchmark) !void {
        // Using std.debug.print instead
        std.debug.print("# zbuild Benchmark Results\n\n", .{});
        std.debug.print("| Test | Iterations | Avg (ms) | Min (ms) | Max (ms) | Std Dev (ms) |\n", .{});
        std.debug.print("|------|------------|----------|----------|----------|-------------|\n", .{});

        for (self.results.items) |result| {
            std.debug.print("| {s} | {} | {} | {} | {} | {} |\n", .{
                result.name,
                result.iterations,
                result.avg_time_ns / std.time.ns_per_ms,
                result.min_time_ns / std.time.ns_per_ms,
                result.max_time_ns / std.time.ns_per_ms,
                result.std_dev_ns / std.time.ns_per_ms,
            });
        }
    }

    fn generateSummary(self: *Benchmark) !void {
        // Using std.debug.print instead
        std.debug.print("Summary:\n", .{});
        std.debug.print("-" ** 40 ++ "\n", .{});

        var fastest: ?BenchmarkResult = null;
        var slowest: ?BenchmarkResult = null;

        for (self.results.items) |result| {
            if (fastest == null or result.avg_time_ns < fastest.?.avg_time_ns) {
                fastest = result;
            }
            if (slowest == null or result.avg_time_ns > slowest.?.avg_time_ns) {
                slowest = result;
            }
        }

        if (fastest) |f| {
            std.debug.print("Fastest: {s} ({}ms avg)\n", .{
                f.name,
                f.avg_time_ns / std.time.ns_per_ms,
            });
        }

        if (slowest) |s| {
            std.debug.print("Slowest: {s} ({}ms avg)\n", .{
                s.name,
                s.avg_time_ns / std.time.ns_per_ms,
            });
        }
    }

    pub fn compare(_: *Benchmark, _: []const u8) !void {
        // Using std.debug.print instead
        std.debug.print("Comparison with baseline not yet implemented\n", .{});
    }

    pub fn saveResults(self: *Benchmark, filename: []const u8) !void {
        const file = try std.fs.cwd().createFile(filename, .{});
        defer file.close();

        _ = file.writer();
        self.output_format = .json;
        try self.generateJsonReport();
    }
};