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
        try makePath(allocator, cache_dir);

        const cache_path = try std.Io.Dir.path.join(allocator, &.{ cache_dir, "cache" });
        defer allocator.free(cache_path);
        try makePath(allocator, cache_path);

        return .{
            .allocator = allocator,
            .cache_dir = try allocator.dupe(u8, cache_dir),
            .index = std.StringHashMap(CacheEntry).init(allocator),
            .remote_enabled = false,
            .remote_url = null,
        };
    }

    /// Helper to create directory path recursively using posix syscalls
    fn makePath(allocator: std.mem.Allocator, path: []const u8) !void {
        var components = std.mem.splitScalar(u8, path, '/');
        var current_path: std.ArrayList(u8) = .empty;
        defer current_path.deinit(allocator);

        while (components.next()) |component| {
            if (component.len == 0) continue;

            if (current_path.items.len > 0) {
                try current_path.append(allocator, '/');
            }
            try current_path.appendSlice(allocator, component);

            // Create null-terminated path for syscall
            try current_path.append(allocator, 0);
            const path_z: [*:0]const u8 = @ptrCast(current_path.items.ptr);
            _ = current_path.pop();

            // Try to create directory (ignore errors for existing dirs)
            const result = std.os.linux.mkdirat(std.posix.AT.FDCWD, path_z, 0o755);
            const err = std.posix.errno(result);
            if (err != .SUCCESS and err != .EXIST) {
                return error.MakePathFailed;
            }
        }
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

        const hash_hex = std.fmt.bytesToHex(hash, .lower);

        const cache_path = try std.Io.Dir.path.join(self.allocator, &.{ self.cache_dir, "cache", &hash_hex });

        // Create file using posix
        const file = try std.posix.openat(std.posix.AT.FDCWD, cache_path, .{ .CREAT = true, .TRUNC = true, .ACCMODE = .WRONLY }, 0o644);
        defer std.posix.close(file);

        var written: usize = 0;
        while (written < bytes.len) {
            const result = std.os.linux.write(file, bytes[written..].ptr, bytes.len - written);
            const err = std.posix.errno(result);
            if (err != .SUCCESS) {
                return error.WriteError;
            }
            written += result;
        }

        // Get current timestamp using clock_gettime
        const ts = std.posix.clock_gettime(.REALTIME) catch std.posix.timespec{ .sec = 0, .nsec = 0 };
        const timestamp: i128 = @as(i128, ts.sec) * std.time.ns_per_s + ts.nsec;

        const entry = CacheEntry{
            .key = try self.allocator.dupe(u8, key),
            .path = cache_path,
            .hash = hash,
            .timestamp = timestamp,
            .size = size,
        };

        try self.index.put(key, entry);

        if (self.remote_enabled) {
            try self.uploadToRemote(key, &entry);
        }
    }

    pub fn retrieve(self: *Cache, key: []const u8, buffer: []u8) !?usize {
        if (self.index.get(key)) |entry| {
            const file = std.posix.openat(std.posix.AT.FDCWD, entry.path, .{}, 0) catch {
                if (self.remote_enabled) {
                    return try self.downloadFromRemote(key, buffer);
                }
                return null;
            };
            defer std.posix.close(file);

            const size = try std.posix.read(file, buffer);
            return size;
        }

        if (self.remote_enabled) {
            return try self.downloadFromRemote(key, buffer);
        }

        return null;
    }

    pub fn exists(self: *Cache, key: []const u8) bool {
        if (self.index.get(key)) |entry| {
            const file = std.posix.openat(std.posix.AT.FDCWD, entry.path, .{}, 0) catch {
                return false;
            };
            std.posix.close(file);
            return true;
        }
        return false;
    }

    pub fn clean(self: *Cache) !void {
        const cache_path = try std.Io.Dir.path.join(self.allocator, &.{ self.cache_dir, "cache" });
        defer self.allocator.free(cache_path);

        // Note: deleteTree is not easily done without Io, so we'll just recreate the directory
        // In a full implementation, you'd use io_uring or walk the directory manually
        try makePath(self.allocator, cache_path);
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