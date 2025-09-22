const std = @import("std");

pub const Cache = struct {
    allocator: std.mem.Allocator,
    cache_dir: []const u8,
    index: std.StringHashMap(CacheEntry),
    remote_enabled: bool,
    remote_url: ?[]const u8,

    const CacheEntry = struct {
        key: []const u8,
        path: []const u8,
        hash: [32]u8,
        timestamp: i128,
        size: usize,
    };

    pub fn init(allocator: std.mem.Allocator, cache_dir: []const u8) !Cache {
        try std.fs.cwd().makePath(cache_dir);

        const cache_path = try std.fs.path.join(allocator, &.{ cache_dir, "cache" });
        try std.fs.cwd().makePath(cache_path);

        return .{
            .allocator = allocator,
            .cache_dir = try allocator.dupe(u8, cache_dir),
            .index = std.StringHashMap(CacheEntry).init(allocator),
            .remote_enabled = false,
            .remote_url = null,
        };
    }

    pub fn deinit(self: *Cache) void {
        self.allocator.free(self.cache_dir);
        self.index.deinit();
        if (self.remote_url) |url| {
            self.allocator.free(url);
        }
    }

    pub fn store(self: *Cache, key: []const u8, data: *const anyopaque, size: usize) !void {
        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        const bytes = @as([*]const u8, @ptrCast(data))[0..size];
        hasher.update(bytes);

        var hash: [32]u8 = undefined;
        hasher.final(&hash);

        const hash_hex = try std.fmt.allocPrint(self.allocator, "{}", .{std.fmt.fmtSliceHexLower(&hash)});
        defer self.allocator.free(hash_hex);

        const cache_path = try std.fs.path.join(self.allocator, &.{ self.cache_dir, "cache", hash_hex });
        defer self.allocator.free(cache_path);

        const file = try std.fs.cwd().createFile(cache_path, .{});
        defer file.close();

        try file.writeAll(bytes);

        const entry = CacheEntry{
            .key = try self.allocator.dupe(u8, key),
            .path = try self.allocator.dupe(u8, cache_path),
            .hash = hash,
            .timestamp = std.time.nanoTimestamp(),
            .size = size,
        };

        try self.index.put(key, entry);

        if (self.remote_enabled) {
            try self.uploadToRemote(key, &entry);
        }
    }

    pub fn retrieve(self: *Cache, key: []const u8, buffer: []u8) !?usize {
        if (self.index.get(key)) |entry| {
            const file = std.fs.cwd().openFile(entry.path, .{}) catch {
                if (self.remote_enabled) {
                    return try self.downloadFromRemote(key, buffer);
                }
                return null;
            };
            defer file.close();

            const size = try file.read(buffer);
            return size;
        }

        if (self.remote_enabled) {
            return try self.downloadFromRemote(key, buffer);
        }

        return null;
    }

    pub fn exists(self: *Cache, key: []const u8) bool {
        if (self.index.get(key)) |entry| {
            std.fs.cwd().access(entry.path, .{}) catch {
                return false;
            };
            return true;
        }
        return false;
    }

    pub fn clean(self: *Cache) !void {
        const cache_path = try std.fs.path.join(self.allocator, &.{ self.cache_dir, "cache" });
        defer self.allocator.free(cache_path);

        std.fs.cwd().deleteTree(cache_path) catch |err| {
            if (err != error.FileNotFound) {
                return err;
            }
        };

        try std.fs.cwd().makePath(cache_path);
        self.index.clearAndFree();

        // Using std.debug.print instead
        std.debug.print("Cache cleaned\n", .{});
    }

    pub fn enableRemoteCache(self: *Cache, url: []const u8) !void {
        self.remote_enabled = true;
        self.remote_url = try self.allocator.dupe(u8, url);
    }

    fn uploadToRemote(_: *Cache, _: []const u8, _: *const CacheEntry) !void {
        // TODO: Implement remote upload
    }

    fn downloadFromRemote(_: *Cache, _: []const u8, _: []u8) !?usize {
        // TODO: Implement remote download
        return null;
    }

    pub fn getStats(self: *const Cache) CacheStats {
        var total_size: usize = 0;
        var entry_count: usize = 0;

        var it = self.index.iterator();
        while (it.next()) |entry| {
            total_size += entry.value_ptr.size;
            entry_count += 1;
        }

        return .{
            .total_size = total_size,
            .entry_count = entry_count,
            .cache_hits = 0,
            .cache_misses = 0,
        };
    }

    pub const CacheStats = struct {
        total_size: usize,
        entry_count: usize,
        cache_hits: usize,
        cache_misses: usize,
    };
};