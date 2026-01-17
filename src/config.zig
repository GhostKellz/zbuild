const std = @import("std");

pub const Config = struct {
    allocator: std.mem.Allocator,
    name: []const u8,
    version: []const u8,
    targets: std.StringHashMap(Target),
    dependencies: std.ArrayList(Dependency),
    compiler_flags: std.ArrayList([]const u8),
    linker_flags: std.ArrayList([]const u8),

    pub const Target = struct {
        name: []const u8,
        type: TargetType,
        sources: std.ArrayList([]const u8),
        dependencies: std.ArrayList([]const u8),
        output: []const u8,
        flags: std.ArrayList([]const u8),
    };

    pub const TargetType = enum {
        executable,
        static_library,
        dynamic_library,
        object,
    };

    pub const Dependency = struct {
        name: []const u8,
        version: []const u8,
        path: ?[]const u8,
        git: ?[]const u8,
    };

    pub fn init(allocator: std.mem.Allocator) Config {
        return .{
            .allocator = allocator,
            .name = "untitled",
            .version = "0.1.0",
            .targets = std.StringHashMap(Target).init(allocator),
            .dependencies = .empty,
            .compiler_flags = .empty,
            .linker_flags = .empty,
        };
    }

    pub fn deinit(self: *Config) void {
        self.targets.deinit();
        self.dependencies.deinit(self.allocator);
        self.compiler_flags.deinit(self.allocator);
        self.linker_flags.deinit(self.allocator);
    }

    pub fn load(allocator: std.mem.Allocator, path: []const u8) !Config {
        // Load config file synchronously using posix openat with AT.FDCWD
        const file = try std.posix.openat(std.posix.AT.FDCWD, path, .{}, 0);
        defer std.posix.close(file);

        // Read file in chunks since fstat is not available on Linux in 0.16.0-dev
        var content: std.ArrayList(u8) = .empty;
        defer content.deinit(allocator);

        var buf: [4096]u8 = undefined;
        while (true) {
            const bytes_read = try std.posix.read(file, &buf);
            if (bytes_read == 0) break;
            try content.appendSlice(allocator, buf[0..bytes_read]);
        }

        return try parseConfig(allocator, content.items);
    }

    pub fn save(self: *const Config, path: []const u8) !void {
        // Save config file synchronously using posix openat with AT.FDCWD
        const file = try std.posix.openat(std.posix.AT.FDCWD, path, .{ .CREAT = true, .TRUNC = true, .ACCMODE = .WRONLY }, 0o644);
        defer std.posix.close(file);

        const config_data = .{
            .name = self.name,
            .version = self.version,
        };

        // Serialize to JSON using Stringify.valueAlloc
        const json_data = try std.json.Stringify.valueAlloc(self.allocator, config_data, .{ .whitespace = .indent_2 });
        defer self.allocator.free(json_data);

        // Write to file
        var written: usize = 0;
        while (written < json_data.len) {
            const result = std.os.linux.write(file, json_data[written..].ptr, json_data.len - written);
            const err = std.posix.errno(result);
            if (err != .SUCCESS) {
                return error.WriteError;
            }
            written += result;
        }
    }

    fn parseConfig(allocator: std.mem.Allocator, content: []const u8) !Config {
        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, content, .{});
        defer parsed.deinit();

        var config = Config.init(allocator);

        if (parsed.value.object.get("name")) |name| {
            config.name = try allocator.dupe(u8, name.string);
        }

        if (parsed.value.object.get("version")) |version| {
            config.version = try allocator.dupe(u8, version.string);
        }

        if (parsed.value.object.get("targets")) |targets| {
            var it = targets.object.iterator();
            while (it.next()) |entry| {
                const target = try parseTarget(allocator, entry.value_ptr.*);
                try config.targets.put(entry.key_ptr.*, target);
            }
        }

        return config;
    }

    fn parseTarget(allocator: std.mem.Allocator, value: std.json.Value) !Target {
        var target = Target{
            .name = "",
            .type = .executable,
            .sources = .empty,
            .dependencies = .empty,
            .output = "",
            .flags = .empty,
        };

        if (value.object.get("name")) |name| {
            target.name = try allocator.dupe(u8, name.string);
        }

        if (value.object.get("type")) |target_type| {
            target.type = std.meta.stringToEnum(TargetType, target_type.string) orelse .executable;
        }

        if (value.object.get("sources")) |sources| {
            for (sources.array.items) |source| {
                try target.sources.append(allocator, try allocator.dupe(u8, source.string));
            }
        }

        if (value.object.get("output")) |output| {
            target.output = try allocator.dupe(u8, output.string);
        }

        return target;
    }
};