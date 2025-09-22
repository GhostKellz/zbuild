const std = @import("std");

pub const Dependency = struct {
    allocator: std.mem.Allocator,
    registry: std.StringHashMap(Package),
    resolved: std.StringHashMap(ResolvedPackage),
    lock_file: []const u8,

    pub const Package = struct {
        name: []const u8,
        version: []const u8,
        source: Source,
        dependencies: std.ArrayList(Requirement),
    };

    pub const Source = union(enum) {
        local: []const u8,
        git: GitSource,
        registry: []const u8,
    };

    pub const GitSource = struct {
        url: []const u8,
        branch: ?[]const u8,
        tag: ?[]const u8,
        commit: ?[]const u8,
    };

    pub const Requirement = struct {
        name: []const u8,
        version_spec: []const u8,
    };

    pub const ResolvedPackage = struct {
        name: []const u8,
        version: []const u8,
        path: []const u8,
        hash: [32]u8,
    };

    pub fn init(allocator: std.mem.Allocator) Dependency {
        return .{
            .allocator = allocator,
            .registry = std.StringHashMap(Package).init(allocator),
            .resolved = std.StringHashMap(ResolvedPackage).init(allocator),
            .lock_file = "zbuild.lock",
        };
    }

    pub fn deinit(self: *Dependency) void {
        self.registry.deinit();
        self.resolved.deinit();
    }

    pub fn addPackage(self: *Dependency, pkg: Package) !void {
        try self.registry.put(pkg.name, pkg);
    }

    pub fn resolve(self: *Dependency) !void {
        // Using std.debug.print instead
        std.debug.print("Resolving dependencies...\n", .{});

        var it = self.registry.iterator();
        while (it.next()) |entry| {
            const pkg = entry.value_ptr.*;
            try self.resolvePackage(&pkg);
        }

        try self.writeLockFile();
    }

    fn resolvePackage(self: *Dependency, pkg: *const Package) !void {
        // Using std.debug.print instead
        std.debug.print("  Resolving {s}@{s}\n", .{ pkg.name, pkg.version });

        const deps_dir = try std.fs.path.join(self.allocator, &.{ ".zbuild", "deps" });
        defer self.allocator.free(deps_dir);
        try std.fs.cwd().makePath(deps_dir);

        const pkg_path = switch (pkg.source) {
            .local => |path| try self.allocator.dupe(u8, path),
            .git => |git| try self.fetchGitPackage(&git, pkg.name),
            .registry => |url| try self.fetchRegistryPackage(url, pkg.name, pkg.version),
        };

        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        try self.hashDirectory(pkg_path, &hasher);

        var hash: [32]u8 = undefined;
        hasher.final(&hash);

        const resolved = ResolvedPackage{
            .name = try self.allocator.dupe(u8, pkg.name),
            .version = try self.allocator.dupe(u8, pkg.version),
            .path = pkg_path,
            .hash = hash,
        };

        try self.resolved.put(pkg.name, resolved);

        for (pkg.dependencies.items) |dep| {
            if (self.registry.get(dep.name)) |dep_pkg| {
                try self.resolvePackage(&dep_pkg);
            } else {
                std.debug.print("Warning: Dependency {s} not found\n", .{dep.name});
            }
        }
    }

    fn fetchGitPackage(self: *Dependency, git: *const GitSource, name: []const u8) ![]const u8 {
        const deps_dir = try std.fs.path.join(self.allocator, &.{ ".zbuild", "deps", name });
        defer self.allocator.free(deps_dir);

        std.fs.cwd().deleteTree(deps_dir) catch {};

        var argv = std.ArrayList([]const u8).init(self.allocator);
        defer argv.deinit();

        try argv.append("git");
        try argv.append("clone");

        if (git.branch) |branch| {
            try argv.append("-b");
            try argv.append(branch);
        }

        try argv.append(git.url);
        try argv.append(deps_dir);

        const result = try std.process.Child.run(.{
            .allocator = self.allocator,
            .argv = argv.items,
        });
        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);

        if (result.term.Exited != 0) {
            return error.GitCloneFailed;
        }

        if (git.commit) |commit| {
            const checkout_result = try std.process.Child.run(.{
                .allocator = self.allocator,
                .argv = &.{ "git", "-C", deps_dir, "checkout", commit },
            });
            defer self.allocator.free(checkout_result.stdout);
            defer self.allocator.free(checkout_result.stderr);

            if (checkout_result.term.Exited != 0) {
                return error.GitCheckoutFailed;
            }
        }

        return self.allocator.dupe(u8, deps_dir);
    }

    fn fetchRegistryPackage(self: *Dependency, url: []const u8, name: []const u8, version: []const u8) ![]const u8 {
        _ = url;
        _ = version;
        const deps_dir = try std.fs.path.join(self.allocator, &.{ ".zbuild", "deps", name });
        try std.fs.cwd().makePath(deps_dir);
        return self.allocator.dupe(u8, deps_dir);
    }

    fn hashDirectory(self: *Dependency, path: []const u8, hasher: anytype) !void {
        var dir = try std.fs.cwd().openDir(path, .{ .iterate = true });
        defer dir.close();

        var walker = try dir.walk(self.allocator);
        defer walker.deinit();

        while (try walker.next()) |entry| {
            if (entry.kind == .file) {
                const file = try dir.openFile(entry.path, .{});
                defer file.close();

                const stat = try file.stat();
                const content = try self.allocator.alloc(u8, stat.size);
                defer self.allocator.free(content);

                _ = try file.readAll(content);
                hasher.update(content);
            }
        }
    }

    pub fn writeLockFile(self: *Dependency) !void {
        const file = try std.fs.cwd().createFile(self.lock_file, .{});
        defer file.close();

        var json = std.json.ObjectMap.init(self.allocator);
        defer json.deinit();

        var packages = std.json.ObjectMap.init(self.allocator);
        defer packages.deinit();

        var it = self.resolved.iterator();
        while (it.next()) |entry| {
            const pkg = entry.value_ptr.*;
            var pkg_json = std.json.ObjectMap.init(self.allocator);

            try pkg_json.put("version", .{ .string = pkg.version });
            try pkg_json.put("path", .{ .string = pkg.path });

            const hash_hex = try std.fmt.allocPrint(self.allocator, "{}", .{std.fmt.fmtSliceHexLower(&pkg.hash)});
            defer self.allocator.free(hash_hex);
            try pkg_json.put("hash", .{ .string = hash_hex });

            try packages.put(pkg.name, .{ .object = pkg_json });
        }

        try json.put("packages", .{ .object = packages });

        const writer = file.writer();
        try std.json.stringify(.{ .object = json }, .{ .whitespace = .indent_2 }, writer);
    }

    pub fn readLockFile(self: *Dependency) !void {
        const file = std.fs.cwd().openFile(self.lock_file, .{}) catch {
            return;
        };
        defer file.close();

        const stat = try file.stat();
        const content = try self.allocator.alloc(u8, stat.size);
        defer self.allocator.free(content);

        _ = try file.readAll(content);
        const parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, content, .{});
        defer parsed.deinit();

        if (parsed.value.object.get("packages")) |packages| {
            var it = packages.object.iterator();
            while (it.next()) |entry| {
                const pkg_data = entry.value_ptr.*;

                var resolved = ResolvedPackage{
                    .name = try self.allocator.dupe(u8, entry.key_ptr.*),
                    .version = try self.allocator.dupe(u8, pkg_data.object.get("version").?.string),
                    .path = try self.allocator.dupe(u8, pkg_data.object.get("path").?.string),
                    .hash = undefined,
                };

                const hash_str = pkg_data.object.get("hash").?.string;
                _ = try std.fmt.hexToBytes(&resolved.hash, hash_str);

                try self.resolved.put(resolved.name, resolved);
            }
        }
    }

    pub fn getPackagePath(self: *Dependency, name: []const u8) ?[]const u8 {
        if (self.resolved.get(name)) |pkg| {
            return pkg.path;
        }
        return null;
    }
};