const std = @import("std");
const Builder = @import("src/builder.zig").Builder;
const Config = @import("src/config.zig").Config;
const Cache = @import("src/cache.zig").Cache;
const Dependency = @import("src/dependency.zig").Dependency;
const ParallelBuilder = @import("src/parallel.zig").ParallelBuilder;
const Watcher = @import("src/watch.zig").Watcher;
const Benchmark = @import("src/benchmark.zig").Benchmark;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        try printUsage();
        return;
    }

    const command = args[1];

    if (std.mem.eql(u8, command, "build")) {
        try runBuild(allocator, args[2..]);
    } else if (std.mem.eql(u8, command, "clean")) {
        try runClean(allocator);
    } else if (std.mem.eql(u8, command, "test")) {
        try runTest(allocator, args[2..]);
    } else if (std.mem.eql(u8, command, "init")) {
        try runInit(allocator);
    } else if (std.mem.eql(u8, command, "watch")) {
        try runWatch(allocator, args[2..]);
    } else if (std.mem.eql(u8, command, "parallel")) {
        try runParallelBuild(allocator, args[2..]);
    } else if (std.mem.eql(u8, command, "benchmark")) {
        try runBenchmark(allocator, args[2..]);
    } else if (std.mem.eql(u8, command, "graph")) {
        try runGraphVisualization(allocator, args[2..]);
    } else {
        try printUsage();
    }
}

fn runBuild(allocator: std.mem.Allocator, args: []const [:0]u8) !void {
    var config = try Config.load(allocator, "zbuild.json");
    defer config.deinit();

    var builder = try Builder.init(allocator, &config);
    defer builder.deinit();

    const target = if (args.len > 0) args[0] else "default";
    try builder.build(target);
}

fn runClean(allocator: std.mem.Allocator) !void {
    const cache = try Cache.init(allocator, ".zbuild");
    defer cache.deinit();
    try cache.clean();
}

fn runTest(allocator: std.mem.Allocator, args: []const [:0]u8) !void {
    var config = try Config.load(allocator, "zbuild.json");
    defer config.deinit();

    var builder = try Builder.init(allocator, &config);
    defer builder.deinit();

    const target = if (args.len > 0) args[0] else "test";
    try builder.runTests(target);
}

fn runInit(allocator: std.mem.Allocator) !void {
    // Using std.debug.print instead
    std.debug.print("Initializing new zbuild project...\n", .{});

    var config = Config.init(allocator);
    defer config.deinit();

    try config.save("zbuild.json");
    std.debug.print("Created zbuild.json\n", .{});
}

fn runWatch(allocator: std.mem.Allocator, args: []const [:0]u8) !void {
    _ = args;
    var config = try Config.load(allocator, "zbuild.json");
    defer config.deinit();

    var builder = try Builder.init(allocator, &config);
    defer builder.deinit();

    var watcher = try Watcher.init(allocator, &config, &builder);
    defer watcher.deinit();

    try watcher.start();
}

fn runParallelBuild(allocator: std.mem.Allocator, args: []const [:0]u8) !void {
    var config = try Config.load(allocator, "zbuild.json");
    defer config.deinit();

    const max_jobs = if (args.len > 0) try std.fmt.parseInt(usize, args[0], 10) else 0;

    var parallel_builder = try ParallelBuilder.init(allocator, max_jobs);
    defer parallel_builder.deinit();

    try parallel_builder.createBuildPlan(&config);
    try parallel_builder.execute();

    const stats = parallel_builder.getStatistics();
    // Using std.debug.print instead
    std.debug.print("\nBuild Statistics:\n", .{});
    std.debug.print("  Total jobs: {}\n", .{stats.total_jobs});
    std.debug.print("  Completed: {}\n", .{stats.completed_jobs});
    std.debug.print("  Failed: {}\n", .{stats.failed_jobs});
    std.debug.print("  Avg duration: {}ms\n", .{stats.avg_duration_ms});
    std.debug.print("  Parallelism: {}\n", .{stats.parallelism});
}

fn runBenchmark(allocator: std.mem.Allocator, args: []const [:0]u8) !void {
    _ = args;
    var config = try Config.load(allocator, "zbuild.json");
    defer config.deinit();

    var builder = try Builder.init(allocator, &config);
    defer builder.deinit();

    var benchmark = Benchmark.init(allocator);
    defer benchmark.deinit();

    try benchmark.runFullSuite(&config, &builder);
}

fn runGraphVisualization(allocator: std.mem.Allocator, args: []const [:0]u8) !void {
    var config = try Config.load(allocator, "zbuild.json");
    defer config.deinit();

    var parallel_builder = try ParallelBuilder.init(allocator, 0);
    defer parallel_builder.deinit();

    try parallel_builder.createBuildPlan(&config);

    const output_file = if (args.len > 0) args[0] else "build_graph.dot";
    const file = try std.fs.cwd().createFile(output_file, .{});
    defer file.close();

    const writer = file.writer();
    try parallel_builder.visualizeBuildGraph(writer);

    // Using std.debug.print instead
    std.debug.print("Build graph saved to {s}\n", .{output_file});
    std.debug.print("Use 'dot -Tpng {s} -o graph.png' to generate image\n", .{output_file});
}

fn printUsage() !void {
    std.debug.print(
        \\zbuild - Modern Build System
        \\
        \\Usage:
        \\  zbuild <command> [options]
        \\
        \\Commands:
        \\  build [target]       Build the project or specific target
        \\  clean               Clean build artifacts
        \\  test [target]       Run tests
        \\  init                Initialize a new zbuild project
        \\  watch               Watch for file changes and rebuild
        \\  parallel [jobs]     Build with parallel workers
        \\  benchmark           Run build performance benchmarks
        \\  graph [output]      Generate build dependency graph
        \\
        \\Examples:
        \\  zbuild build main            Build main target
        \\  zbuild parallel 8            Build with 8 parallel workers
        \\  zbuild watch                 Watch mode for development
        \\  zbuild benchmark             Performance analysis
        \\  zbuild graph deps.dot        Export dependency graph
        \\
    , .{});
}