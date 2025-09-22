const std = @import("std");
const Builder = @import("builder.zig").Builder;
const Config = @import("config.zig").Config;

pub const Watcher = struct {
    allocator: std.mem.Allocator,
    config: *Config,
    builder: *Builder,
    watch_paths: std.ArrayList([]const u8),
    ignore_patterns: std.ArrayList([]const u8),
    file_states: std.StringHashMap(FileState),
    poll_interval_ms: u64,
    running: bool,
    rebuild_delay_ms: u64,
    last_build_time: i64,

    const FileState = struct {
        path: []const u8,
        size: u64,
        mtime: i128,
        hash: ?[32]u8,
    };

    pub fn init(allocator: std.mem.Allocator, config: *Config, builder: *Builder) !Watcher {
        var watcher = Watcher{
            .allocator = allocator,
            .config = config,
            .builder = builder,
            .watch_paths = std.ArrayList([]const u8).init(allocator),
            .ignore_patterns = std.ArrayList([]const u8).init(allocator),
            .file_states = std.StringHashMap(FileState).init(allocator),
            .poll_interval_ms = 100,
            .running = false,
            .rebuild_delay_ms = 200,
            .last_build_time = 0,
        };

        try watcher.addDefaultIgnorePatterns();
        try watcher.scanInitialFiles();

        return watcher;
    }

    pub fn deinit(self: *Watcher) void {
        self.watch_paths.deinit();
        self.ignore_patterns.deinit();
        self.file_states.deinit();
    }

    fn addDefaultIgnorePatterns(self: *Watcher) !void {
        try self.ignore_patterns.append(".git");
        try self.ignore_patterns.append(".zbuild");
        try self.ignore_patterns.append("target");
        try self.ignore_patterns.append("node_modules");
        try self.ignore_patterns.append("*.o");
        try self.ignore_patterns.append("*.a");
        try self.ignore_patterns.append("*.so");
        try self.ignore_patterns.append("*.dylib");
        try self.ignore_patterns.append("*.exe");
        try self.ignore_patterns.append("*.dll");
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
        var dir = try std.fs.cwd().openDir(path, .{ .iterate = true });
        defer dir.close();

        var walker = try dir.walk(self.allocator);
        defer walker.deinit();

        while (try walker.next()) |entry| {
            if (entry.kind != .file) continue;

            if (self.shouldIgnore(entry.path)) continue;

            const full_path = try std.fs.path.join(self.allocator, &.{ path, entry.path });
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
        const file = std.fs.cwd().openFile(path, .{}) catch return;
        defer file.close();

        const stat = try file.stat();

        const state = FileState{
            .path = try self.allocator.dupe(u8, path),
            .size = stat.size,
            .mtime = stat.mtime,
            .hash = null,
        };

        try self.file_states.put(state.path, state);
    }

    pub fn start(self: *Watcher) !void {
        // Using std.debug.print instead
        std.debug.print("Starting file watcher...\n", .{});
        std.debug.print("Watching {} files\n", .{self.file_states.count()});
        std.debug.print("Press Ctrl+C to stop\n\n", .{});

        self.running = true;

        try self.builder.build("default");
        self.last_build_time = std.time.milliTimestamp();

        while (self.running) {
            const changes = try self.detectChanges();
            defer changes.deinit();

            if (changes.items.len > 0) {
                try self.handleChanges(changes.items);
            }

            std.time.sleep(self.poll_interval_ms * std.time.ns_per_ms);
        }
    }

    pub fn stop(self: *Watcher) void {
        self.running = false;
    }

    fn detectChanges(self: *Watcher) !std.ArrayList(FileChange) {
        var changes = std.ArrayList(FileChange).init(self.allocator);

        var it = self.file_states.iterator();
        while (it.next()) |entry| {
            const stored_state = entry.value_ptr.*;

            const file = std.fs.cwd().openFile(stored_state.path, .{}) catch {
                try changes.append(.{
                    .type = .deleted,
                    .path = stored_state.path,
                });
                continue;
            };
            defer file.close();

            const current_stat = try file.stat();

            if (current_stat.mtime > stored_state.mtime or
                current_stat.size != stored_state.size)
            {
                try changes.append(.{
                    .type = .modified,
                    .path = stored_state.path,
                });

                entry.value_ptr.mtime = current_stat.mtime;
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
        // Using std.debug.print instead

        for (changes) |change| {
            const action = switch (change.type) {
                .created => "Created",
                .modified => "Modified",
                .deleted => "Deleted",
            };
            std.debug.print("[{}] {s}: {s}\n", .{
                std.time.timestamp(),
                action,
                change.path,
            });
        }

        const now = std.time.milliTimestamp();
        if (now - self.last_build_time < @as(i64, @intCast(self.rebuild_delay_ms))) {
            return;
        }

        std.debug.print("\nRebuilding...\n", .{});
        const start_time = std.time.milliTimestamp();

        self.builder.build("default") catch |err| {
            std.debug.print("Build failed: {}\n", .{err});
            return;
        };

        const elapsed = std.time.milliTimestamp() - start_time;
        std.debug.print("Build completed in {}ms\n\n", .{elapsed});

        self.last_build_time = std.time.milliTimestamp();
    }

    pub fn addWatchPath(self: *Watcher, path: []const u8) !void {
        try self.watch_paths.append(try self.allocator.dupe(u8, path));
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
        try self.ignore_patterns.append(try self.allocator.dupe(u8, pattern));
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