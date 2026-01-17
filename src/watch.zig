const std = @import("std");
const Builder = @import("builder.zig").Builder;
const Config = @import("config.zig").Config;

pub const Watcher = struct {
    allocator: std.mem.Allocator,
    config: *Config,
    builder: *Builder,
    io: std.Io,
    watch_paths: std.ArrayList([]const u8),
    ignore_patterns: std.ArrayList([]const u8),
    file_states: std.StringHashMap(FileState),
    poll_interval_ms: u64,
    running: bool,
    rebuild_delay_ms: u64,
    last_build_time: std.time.Instant,

    const FileState = struct {
        path: []const u8,
        size: u64,
        mtime: i96,
        hash: ?[32]u8,
    };

    pub fn init(allocator: std.mem.Allocator, config: *Config, builder: *Builder, io: std.Io) !Watcher {
        var watcher = Watcher{
            .allocator = allocator,
            .config = config,
            .builder = builder,
            .io = io,
            .watch_paths = .empty,
            .ignore_patterns = .empty,
            .file_states = std.StringHashMap(FileState).init(allocator),
            .poll_interval_ms = 100,
            .running = false,
            .rebuild_delay_ms = 200,
            .last_build_time = std.time.Instant.now() catch std.time.Instant{ .timestamp = std.posix.timespec{ .sec = 0, .nsec = 0 } },
        };

        try watcher.addDefaultIgnorePatterns();
        try watcher.scanInitialFiles();

        return watcher;
    }

    pub fn deinit(self: *Watcher) void {
        self.watch_paths.deinit(self.allocator);
        self.ignore_patterns.deinit(self.allocator);
        self.file_states.deinit();
    }

    fn addDefaultIgnorePatterns(self: *Watcher) !void {
        try self.ignore_patterns.append(self.allocator, ".git");
        try self.ignore_patterns.append(self.allocator, ".zbuild");
        try self.ignore_patterns.append(self.allocator, "target");
        try self.ignore_patterns.append(self.allocator, "node_modules");
        try self.ignore_patterns.append(self.allocator, "*.o");
        try self.ignore_patterns.append(self.allocator, "*.a");
        try self.ignore_patterns.append(self.allocator, "*.so");
        try self.ignore_patterns.append(self.allocator, "*.dylib");
        try self.ignore_patterns.append(self.allocator, "*.exe");
        try self.ignore_patterns.append(self.allocator, "*.dll");
    }

    fn scanInitialFiles(self: *Watcher) !void {
        var target_it = self.config.targets.iterator();
        while (target_it.next()) |entry| {
            const target = entry.value_ptr.*;
            for (target.sources.items) |source| {
                try self.addFile(source);
            }
        }

        try self.scanDirectory(".");
    }

    fn scanDirectory(self: *Watcher, path: []const u8) !void {
        var dir = try std.Io.Dir.openDir(.cwd(), self.io, path, .{ .iterate = true });
        defer dir.close(self.io);

        var walker = try dir.walk(self.allocator);
        defer walker.deinit();

        while (try walker.next(self.io)) |entry| {
            if (entry.kind != .file) continue;

            if (self.shouldIgnore(entry.path)) continue;

            const full_path = try std.Io.Dir.path.join(self.allocator, &.{ path, entry.path });
            defer self.allocator.free(full_path);

            try self.addFile(full_path);
        }
    }

    fn shouldIgnore(self: *Watcher, path: []const u8) bool {
        for (self.ignore_patterns.items) |pattern| {
            if (std.mem.indexOf(u8, path, pattern) != null) {
                return true;
            }

            if (std.mem.endsWith(u8, pattern, "*")) {
                const prefix = pattern[0 .. pattern.len - 1];
                if (std.mem.startsWith(u8, path, prefix)) {
                    return true;
                }
            }

            if (std.mem.startsWith(u8, pattern, "*")) {
                const suffix = pattern[1..];
                if (std.mem.endsWith(u8, path, suffix)) {
                    return true;
                }
            }
        }
        return false;
    }

    fn addFile(self: *Watcher, path: []const u8) !void {
        const file = std.Io.Dir.openFile(.cwd(), self.io, path, .{}) catch return;
        defer file.close(self.io);

        const stat = try file.stat(self.io);

        const state = FileState{
            .path = try self.allocator.dupe(u8, path),
            .size = stat.size,
            .mtime = stat.mtime.nanoseconds,
            .hash = null,
        };

        try self.file_states.put(state.path, state);
    }

    pub fn start(self: *Watcher) !void {
        std.debug.print("Starting file watcher...\n", .{});
        std.debug.print("Watching {} files\n", .{self.file_states.count()});
        std.debug.print("Press Ctrl+C to stop\n\n", .{});

        self.running = true;

        try self.builder.build("default");
        self.last_build_time = std.time.Instant.now() catch std.time.Instant{ .timestamp = std.posix.timespec{ .sec = 0, .nsec = 0 } };

        while (self.running) {
            var changes = try self.detectChanges();
            defer changes.deinit(self.allocator);

            if (changes.items.len > 0) {
                try self.handleChanges(changes.items);
            }

            // Sleep using the Io interface
            std.Io.sleep(self.io, .fromMilliseconds(@intCast(self.poll_interval_ms)), .awake) catch {};
        }
    }

    pub fn stop(self: *Watcher) void {
        self.running = false;
    }

    fn detectChanges(self: *Watcher) !std.ArrayList(FileChange) {
        var changes: std.ArrayList(FileChange) = .empty;

        var it = self.file_states.iterator();
        while (it.next()) |entry| {
            const stored_state = entry.value_ptr.*;

            const file = std.Io.Dir.openFile(.cwd(), self.io, stored_state.path, .{}) catch {
                try changes.append(self.allocator, .{
                    .type = .deleted,
                    .path = stored_state.path,
                });
                continue;
            };
            defer file.close(self.io);

            const current_stat = try file.stat(self.io);

            if (current_stat.mtime.nanoseconds > stored_state.mtime or
                current_stat.size != stored_state.size)
            {
                try changes.append(self.allocator, .{
                    .type = .modified,
                    .path = stored_state.path,
                });

                entry.value_ptr.mtime = current_stat.mtime.nanoseconds;
                entry.value_ptr.size = current_stat.size;
            }
        }

        return changes;
    }

    const FileChange = struct {
        type: ChangeType,
        path: []const u8,
    };

    const ChangeType = enum {
        created,
        modified,
        deleted,
    };

    fn handleChanges(self: *Watcher, changes: []const FileChange) !void {
        // Get current wall clock time for logging
        const ts = std.posix.clock_gettime(.REALTIME) catch std.posix.timespec{ .sec = 0, .nsec = 0 };

        for (changes) |change| {
            const action = switch (change.type) {
                .created => "Created",
                .modified => "Modified",
                .deleted => "Deleted",
            };
            std.debug.print("[{}] {s}: {s}\n", .{
                ts.sec,
                action,
                change.path,
            });
        }

        // Check if enough time has passed since last build
        const now = std.time.Instant.now() catch std.time.Instant{ .timestamp = std.posix.timespec{ .sec = 0, .nsec = 0 } };
        const elapsed_ns = now.since(self.last_build_time);
        const elapsed_ms = elapsed_ns / std.time.ns_per_ms;

        if (elapsed_ms < self.rebuild_delay_ms) {
            return;
        }

        std.debug.print("\nRebuilding...\n", .{});
        const start_time = std.time.Instant.now() catch std.time.Instant{ .timestamp = std.posix.timespec{ .sec = 0, .nsec = 0 } };

        self.builder.build("default") catch |err| {
            std.debug.print("Build failed: {}\n", .{err});
            return;
        };

        const end_time = std.time.Instant.now() catch std.time.Instant{ .timestamp = std.posix.timespec{ .sec = 0, .nsec = 0 } };
        const build_elapsed_ns = end_time.since(start_time);
        const build_elapsed_ms = build_elapsed_ns / std.time.ns_per_ms;
        std.debug.print("Build completed in {}ms\n\n", .{build_elapsed_ms});

        self.last_build_time = end_time;
    }

    pub fn addWatchPath(self: *Watcher, path: []const u8) !void {
        try self.watch_paths.append(self.allocator, try self.allocator.dupe(u8, path));
        try self.scanDirectory(path);
    }

    pub fn removeWatchPath(self: *Watcher, path: []const u8) void {
        for (self.watch_paths.items, 0..) |watch_path, i| {
            if (std.mem.eql(u8, watch_path, path)) {
                _ = self.watch_paths.swapRemove(i);
                self.allocator.free(watch_path);
                break;
            }
        }
    }

    pub fn addIgnorePattern(self: *Watcher, pattern: []const u8) !void {
        try self.ignore_patterns.append(self.allocator, try self.allocator.dupe(u8, pattern));
    }

    pub fn clearFileCache(self: *Watcher) void {
        var it = self.file_states.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.file_states.clearAndFree();
    }

    pub fn getWatchedFileCount(self: *const Watcher) usize {
        return self.file_states.count();
    }

    pub fn setPollInterval(self: *Watcher, interval_ms: u64) void {
        self.poll_interval_ms = interval_ms;
    }

    pub fn setRebuildDelay(self: *Watcher, delay_ms: u64) void {
        self.rebuild_delay_ms = delay_ms;
    }
};
