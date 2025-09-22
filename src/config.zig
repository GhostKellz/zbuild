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
            .dependencies = std.ArrayList(Dependency){},
            .compiler_flags = std.ArrayList([]const u8){},
            .linker_flags = std.ArrayList([]const u8){},
        };
    }

    pub fn deinit(self: *Config) void {
        self.targets.deinit();
        self.dependencies.deinit(self.allocator);
        self.compiler_flags.deinit(self.allocator);
        self.linker_flags.deinit(self.allocator);
    }

    pub fn load(allocator: std.mem.Allocator, path: []const u8) !Config {
        const file = try std.fs.cwd().openFile(path, .{});
        defer file.close();

        const stat = try file.stat();
        const content = try allocator.alloc(u8, stat.size);
        defer allocator.free(content);

        _ = try file.readAll(content);

        return try parseConfig(allocator, content);
    }

    pub fn save(self: *const Config, path: []const u8) !void {
        const file = try std.fs.cwd().createFile(path, .{});
        defer file.close();

        var json = std.json.ObjectMap.init(self.allocator);
        defer json.deinit();

        try json.put("name", .{ .string = self.name });
        try json.put("version", .{ .string = self.version });

        const writer = file.writer();
        try std.json.stringify(.{ .object = json }, .{ .whitespace = .indent_2 }, writer);
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
            .sources = std.ArrayList([]const u8){},
            .dependencies = std.ArrayList([]const u8){},
            .output = "",
            .flags = std.ArrayList([]const u8){},
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