const std = @import("std");

pub const Cargo = struct {
    allocator: std.mem.Allocator,
    manifest: CargoManifest,
    workspace: ?WorkspaceConfig,

    pub const CargoManifest = struct {
        package: Package,
        dependencies: std.StringHashMap(Dependency),
        dev_dependencies: std.StringHashMap(Dependency),
        build_dependencies: std.StringHashMap(Dependency),
        features: std.StringHashMap(std.ArrayList([]const u8)),
        target: std.StringHashMap(TargetConfig),
        profile: std.StringHashMap(Profile),
        bin: std.ArrayList(Binary),
        lib: ?Library,
    };

    pub const Package = struct {
        name: []const u8,
        version: []const u8,
        authors: std.ArrayList([]const u8),
        edition: []const u8,
        description: ?[]const u8,
        license: ?[]const u8,
        repository: ?[]const u8,
        homepage: ?[]const u8,
        documentation: ?[]const u8,
        build: ?[]const u8,
        links: ?[]const u8,
        publish: bool,
    };

    pub const Dependency = struct {
        version: ?[]const u8,
        path: ?[]const u8,
        git: ?[]const u8,
        branch: ?[]const u8,
        tag: ?[]const u8,
        rev: ?[]const u8,
        features: std.ArrayList([]const u8),
        optional: bool,
        default_features: bool,
    };

    pub const TargetConfig = struct {
        dependencies: std.StringHashMap(Dependency),
    };

    pub const Profile = struct {
        opt_level: u8,
        debug: bool,
        debug_assertions: bool,
        overflow_checks: bool,
        lto: bool,
        panic: []const u8,
        incremental: bool,
        codegen_units: u32,
        rpath: bool,
    };

    pub const Binary = struct {
        name: []const u8,
        path: []const u8,
        is_test: bool,
        is_bench: bool,
        is_doc: bool,
        is_plugin: bool,
        has_harness: bool,
        required_features: std.ArrayList([]const u8),
    };

    pub const Library = struct {
        name: ?[]const u8,
        path: ?[]const u8,
        crate_type: std.ArrayList([]const u8),
        is_test: bool,
        is_bench: bool,
        is_doc: bool,
        is_plugin: bool,
        has_harness: bool,
    };

    pub const WorkspaceConfig = struct {
        members: std.ArrayList([]const u8),
        exclude: std.ArrayList([]const u8),
        default_members: std.ArrayList([]const u8),
        resolver: ?[]const u8,
    };

    pub fn init(allocator: std.mem.Allocator) Cargo {
        return .{
            .allocator = allocator,
            .manifest = CargoManifest{
                .package = Package{
                    .name = "",
                    .version = "0.1.0",
                    .authors = std.ArrayList([]const u8).init(allocator),
                    .edition = "2021",
                    .description = null,
                    .license = null,
                    .repository = null,
                    .homepage = null,
                    .documentation = null,
                    .build = null,
                    .links = null,
                    .publish = true,
                },
                .dependencies = std.StringHashMap(Dependency).init(allocator),
                .dev_dependencies = std.StringHashMap(Dependency).init(allocator),
                .build_dependencies = std.StringHashMap(Dependency).init(allocator),
                .features = std.StringHashMap(std.ArrayList([]const u8)).init(allocator),
                .target = std.StringHashMap(TargetConfig).init(allocator),
                .profile = std.StringHashMap(Profile).init(allocator),
                .bin = std.ArrayList(Binary).init(allocator),
                .lib = null,
            },
            .workspace = null,
        };
    }

    pub fn deinit(self: *Cargo) void {
        self.manifest.package.authors.deinit();
        self.manifest.dependencies.deinit();
        self.manifest.dev_dependencies.deinit();
        self.manifest.build_dependencies.deinit();

        var features_it = self.manifest.features.iterator();
        while (features_it.next()) |entry| {
            entry.value_ptr.deinit();
        }
        self.manifest.features.deinit();

        self.manifest.target.deinit();
        self.manifest.profile.deinit();
        self.manifest.bin.deinit();
    }

    pub fn parseToml(allocator: std.mem.Allocator, content: []const u8) !Cargo {
        var cargo = Cargo.init(allocator);

        // Basic TOML parsing - for now we'll do simple key-value extraction
        // In a production system, we'd use a proper TOML parser
        const lines = std.mem.split(u8, content, "\n");
        var current_section: []const u8 = "";
        var line_it = lines;

        while (line_it.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");

            if (trimmed.len == 0 or trimmed[0] == '#') continue;

            // Section headers
            if (trimmed[0] == '[' and trimmed[trimmed.len - 1] == ']') {
                current_section = trimmed[1..trimmed.len - 1];
                continue;
            }

            // Key-value pairs
            if (std.mem.indexOf(u8, trimmed, " = ")) |eq_pos| {
                const key = std.mem.trim(u8, trimmed[0..eq_pos], " \t");
                var value = std.mem.trim(u8, trimmed[eq_pos + 3..], " \t");

                // Remove quotes
                if (value.len >= 2 and value[0] == '"' and value[value.len - 1] == '"') {
                    value = value[1..value.len - 1];
                }

                if (std.mem.eql(u8, current_section, "package")) {
                    if (std.mem.eql(u8, key, "name")) {
                        cargo.manifest.package.name = try allocator.dupe(u8, value);
                    } else if (std.mem.eql(u8, key, "version")) {
                        cargo.manifest.package.version = try allocator.dupe(u8, value);
                    } else if (std.mem.eql(u8, key, "edition")) {
                        cargo.manifest.package.edition = try allocator.dupe(u8, value);
                    } else if (std.mem.eql(u8, key, "description")) {
                        cargo.manifest.package.description = try allocator.dupe(u8, value);
                    }
                } else if (std.mem.eql(u8, current_section, "dependencies")) {
                    const dep = Dependency{
                        .version = try allocator.dupe(u8, value),
                        .path = null,
                        .git = null,
                        .branch = null,
                        .tag = null,
                        .rev = null,
                        .features = std.ArrayList([]const u8).init(allocator),
                        .optional = false,
                        .default_features = true,
                    };
                    try cargo.manifest.dependencies.put(try allocator.dupe(u8, key), dep);
                }
            }
        }

        // Set defaults if not specified
        if (cargo.manifest.package.name.len == 0) {
            cargo.manifest.package.name = try allocator.dupe(u8, "unnamed");
        }
        if (cargo.manifest.package.version.len == 0) {
            cargo.manifest.package.version = try allocator.dupe(u8, "0.1.0");
        }
        if (cargo.manifest.package.edition.len == 0) {
            cargo.manifest.package.edition = try allocator.dupe(u8, "2021");
        }

        return cargo;
    }

    pub fn loadFromFile(allocator: std.mem.Allocator, path: []const u8) !Cargo {
        const file = try std.fs.cwd().openFile(path, .{});
        defer file.close();

        const stat = try file.stat();
        const content = try allocator.alloc(u8, stat.size);
        defer allocator.free(content);

        _ = try file.readAll(content);
        return try parseToml(allocator, content);
    }

    pub fn toBuildConfig(self: *const Cargo, allocator: std.mem.Allocator) !BuildConfig {
        var config = BuildConfig{
            .allocator = allocator,
            .crate_name = try allocator.dupe(u8, self.manifest.package.name),
            .crate_type = .bin,
            .edition = try allocator.dupe(u8, self.manifest.package.edition),
            .src_path = try allocator.dupe(u8, "src/main.rs"),
            .out_dir = try allocator.dupe(u8, "target"),
            .target_dir = try allocator.dupe(u8, "target/debug"),
            .deps = std.ArrayList([]const u8).init(allocator),
            .features = std.ArrayList([]const u8).init(allocator),
            .rustc_flags = std.ArrayList([]const u8).init(allocator),
        };

        if (self.manifest.lib) |lib| {
            config.crate_type = .lib;
            if (lib.path) |path| {
                config.src_path = try allocator.dupe(u8, path);
            } else {
                config.src_path = try allocator.dupe(u8, "src/lib.rs");
            }
        }

        try config.rustc_flags.append(allocator, "--edition");
        try config.rustc_flags.append(allocator, self.manifest.package.edition);

        var deps_it = self.manifest.dependencies.iterator();
        while (deps_it.next()) |entry| {
            try config.deps.append(allocator, try allocator.dupe(u8, entry.key_ptr.*));
        }

        return config;
    }

    pub const BuildConfig = struct {
        allocator: std.mem.Allocator,
        crate_name: []const u8,
        crate_type: CrateType,
        edition: []const u8,
        src_path: []const u8,
        out_dir: []const u8,
        target_dir: []const u8,
        deps: std.ArrayList([]const u8),
        features: std.ArrayList([]const u8),
        rustc_flags: std.ArrayList([]const u8),

        pub const CrateType = enum {
            bin,
            lib,
            rlib,
            dylib,
            cdylib,
            staticlib,
            proc_macro,
        };

        pub fn deinit(self: *BuildConfig) void {
            self.allocator.free(self.crate_name);
            self.allocator.free(self.edition);
            self.allocator.free(self.src_path);
            self.allocator.free(self.out_dir);
            self.allocator.free(self.target_dir);
            self.deps.deinit();
            self.features.deinit();
            self.rustc_flags.deinit();
        }
    };

    pub fn runCargoBuild(self: *const Cargo, allocator: std.mem.Allocator) !void {
        _ = self;
        var argv = std.ArrayList([]const u8).init(allocator);
        defer argv.deinit();

        try argv.append("cargo");
        try argv.append("build");

        const result = try std.process.Child.run(.{
            .allocator = allocator,
            .argv = argv.items,
        });
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);

        if (result.term.Exited != 0) {
            std.debug.print("Cargo build failed:\n{s}\n", .{result.stderr});
            return error.CargoBuildFailed;
        }
    }

    pub fn generateCargoToml(self: *const Cargo, allocator: std.mem.Allocator) ![]const u8 {
        var buffer = std.ArrayList(u8).init(allocator);
        const writer = buffer.writer();

        try writer.print("[package]\n", .{});
        try writer.print("name = \"{s}\"\n", .{self.manifest.package.name});
        try writer.print("version = \"{s}\"\n", .{self.manifest.package.version});
        try writer.print("edition = \"{s}\"\n", .{self.manifest.package.edition});

        if (self.manifest.package.description) |desc| {
            try writer.print("description = \"{s}\"\n", .{desc});
        }

        if (self.manifest.package.authors.items.len > 0) {
            try writer.print("authors = [", .{});
            for (self.manifest.package.authors.items, 0..) |author, i| {
                if (i > 0) try writer.print(", ", .{});
                try writer.print("\"{s}\"", .{author});
            }
            try writer.print("]\n", .{});
        }

        if (self.manifest.dependencies.count() > 0) {
            try writer.print("\n[dependencies]\n", .{});
            var deps_it = self.manifest.dependencies.iterator();
            while (deps_it.next()) |entry| {
                const dep = entry.value_ptr.*;
                if (dep.version) |version| {
                    try writer.print("{s} = \"{s}\"\n", .{ entry.key_ptr.*, version });
                } else if (dep.path) |path| {
                    try writer.print("{s} = {{ path = \"{s}\" }}\n", .{ entry.key_ptr.*, path });
                } else if (dep.git) |git| {
                    try writer.print("{s} = {{ git = \"{s}\"", .{ entry.key_ptr.*, git });
                    if (dep.branch) |branch| {
                        try writer.print(", branch = \"{s}\"", .{branch});
                    }
                    try writer.print(" }}\n", .{});
                }
            }
        }

        return buffer.toOwnedSlice();
    }
};