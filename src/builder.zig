const std = @import("std");
const Config = @import("config.zig").Config;
const Cache = @import("cache.zig").Cache;
const Dependency = @import("dependency.zig").Dependency;
const Cargo = @import("cargo.zig").Cargo;
const CrossCompile = @import("cross_compile.zig").CrossCompile;

pub const Builder = struct {
    allocator: std.mem.Allocator,
    config: *const Config,
    cache: Cache,
    build_dir: []const u8,
    artifacts: std.StringHashMap(Artifact),
    build_graph: std.StringHashMap(std.ArrayList([]const u8)),
    rust_crates: std.StringHashMap(RustCrate),
    cross_compile: CrossCompile,

    const Artifact = struct {
        path: []const u8,
        timestamp: i128,
        hash: [32]u8,
    };

    pub const RustCrate = struct {
        name: []const u8,
        path: []const u8,
        crate_type: CrateType,
        features: std.ArrayList([]const u8),
        target: ?std.Target,
        optimize: OptimizeMode,
        ffi_headers: ?FFIConfig,
        cross_compile: ?CrossCompileConfig,

        pub const CrossCompileConfig = struct {
            rust_target: []const u8,
            linker: ?[]const u8,
            sysroot: ?[]const u8,
            env_vars: std.StringHashMap([]const u8),
        };

        pub const CrateType = enum {
            bin,
            lib,
            rlib,
            dylib,
            cdylib,
            staticlib,
            proc_macro,
        };

        pub const OptimizeMode = enum {
            Debug,
            ReleaseSafe,
            ReleaseFast,
            ReleaseSmall,
        };

        pub const FFIConfig = struct {
            output_dir: []const u8,
            header_name: []const u8,
            include_guard: ?[]const u8,
        };

        pub fn init(allocator: std.mem.Allocator, name: []const u8, path: []const u8) RustCrate {
            return .{
                .name = name,
                .path = path,
                .crate_type = .lib,
                .features = std.ArrayList([]const u8).init(allocator),
                .target = null,
                .optimize = .ReleaseFast,
                .ffi_headers = null,
                .cross_compile = null,
            };
        }

        pub fn deinit(self: *RustCrate) void {
            self.features.deinit();
            if (self.cross_compile) |*cc| {
                cc.env_vars.deinit();
            }
        }
    };

    pub fn init(allocator: std.mem.Allocator, config: *const Config) !Builder {
        const build_dir = try std.fs.path.join(allocator, &.{ ".zbuild", "build" });
        try std.fs.cwd().makePath(build_dir);

        return .{
            .allocator = allocator,
            .config = config,
            .cache = try Cache.init(allocator, ".zbuild"),
            .build_dir = build_dir,
            .artifacts = std.StringHashMap(Artifact).init(allocator),
            .build_graph = std.StringHashMap(std.ArrayList([]const u8)).init(allocator),
            .rust_crates = std.StringHashMap(RustCrate).init(allocator),
            .cross_compile = CrossCompile.init(allocator),
        };
    }

    pub fn deinit(self: *Builder) void {
        self.cache.deinit();
        self.artifacts.deinit();
        self.build_graph.deinit();

        var rust_it = self.rust_crates.iterator();
        while (rust_it.next()) |entry| {
            entry.value_ptr.deinit();
        }
        self.rust_crates.deinit();
        self.cross_compile.deinit();
    }

    // API function to add Rust crates - from the wishlist
    pub fn addRustCrate(self: *Builder, options: struct {
        name: []const u8,
        path: []const u8,
        crate_type: RustCrate.CrateType = .cdylib,
        features: []const []const u8 = &[_][]const u8{},
        target: ?std.Target = null,
        optimize: RustCrate.OptimizeMode = .ReleaseFast,
        cross_compile: ?struct {
            rust_target: []const u8,
            linker: ?[]const u8 = null,
            sysroot: ?[]const u8 = null,
        } = null,
    }) !*RustCrate {
        var crate = RustCrate.init(self.allocator, options.name, options.path);
        crate.crate_type = options.crate_type;
        crate.target = options.target;
        crate.optimize = options.optimize;

        for (options.features) |feature| {
            try crate.features.append(self.allocator, try self.allocator.dupe(u8, feature));
        }

        // Set up cross-compilation if specified
        if (options.cross_compile) |cc| {
            crate.cross_compile = RustCrate.CrossCompileConfig{
                .rust_target = try self.allocator.dupe(u8, cc.rust_target),
                .linker = if (cc.linker) |linker| try self.allocator.dupe(u8, linker) else null,
                .sysroot = if (cc.sysroot) |sysroot| try self.allocator.dupe(u8, sysroot) else null,
                .env_vars = std.StringHashMap([]const u8).init(self.allocator),
            };
        }

        try self.rust_crates.put(options.name, crate);
        return self.rust_crates.getPtr(options.name).?;
    }

    // Generate FFI headers for a Rust crate
    pub fn generateHeaders(self: *Builder, crate: *RustCrate, options: struct {
        output_dir: []const u8,
        header_name: []const u8,
        include_guard: ?[]const u8 = null,
    }) !void {
        crate.ffi_headers = RustCrate.FFIConfig{
            .output_dir = try self.allocator.dupe(u8, options.output_dir),
            .header_name = try self.allocator.dupe(u8, options.header_name),
            .include_guard = if (options.include_guard) |guard| try self.allocator.dupe(u8, guard) else null,
        };

        // Ensure output directory exists
        try std.fs.cwd().makePath(options.output_dir);

        // Run cbindgen to generate headers
        try self.runCBindGen(crate);
    }

    fn runCBindGen(self: *Builder, crate: *RustCrate) !void {
        if (crate.ffi_headers == null) return;

        const ffi_config = crate.ffi_headers.?;
        const header_path = try std.fs.path.join(self.allocator, &.{ ffi_config.output_dir, ffi_config.header_name });
        defer self.allocator.free(header_path);

        var argv = std.ArrayList([]const u8).init(self.allocator);
        defer argv.deinit();

        try argv.append("cbindgen");
        try argv.append("--crate");
        try argv.append(crate.name);
        try argv.append("--output");
        try argv.append(header_path);
        try argv.append("--lang");
        try argv.append("c");

        if (ffi_config.include_guard) |guard| {
            try argv.append("--cpp-compat");
            try argv.append("--include-guard");
            try argv.append(guard);
        }

        const result = try std.process.Child.run(.{
            .allocator = self.allocator,
            .argv = argv.items,
            .cwd = crate.path,
        });
        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);

        if (result.term.Exited != 0) {
            std.debug.print("cbindgen failed:\n{s}\n", .{result.stderr});
            return error.CBindGenFailed;
        }

        std.debug.print("Generated FFI headers: {s}\n", .{header_path});
    }

    // Link a Rust crate to a Zig executable - from the wishlist API
    pub fn linkRustCrate(self: *Builder, executable: anytype, rust_crate: *RustCrate) !void {
        _ = executable; // Will be used in actual implementation

        // Add library search path
        const lib_path = try std.fs.path.join(self.allocator, &.{ self.build_dir, "rust-target", "release" });
        defer self.allocator.free(lib_path);

        // Generate the library name based on crate type
        const lib_name = switch (rust_crate.crate_type) {
            .cdylib => try std.fmt.allocPrint(self.allocator, "lib{s}.so", .{rust_crate.name}),
            .staticlib => try std.fmt.allocPrint(self.allocator, "lib{s}.a", .{rust_crate.name}),
            else => return error.UnsupportedCrateType,
        };
        defer self.allocator.free(lib_name);

        std.debug.print("Linking Rust crate: {s} -> {s}\n", .{ rust_crate.name, lib_name });

        // In a real implementation, this would add the library to the executable's link step
        // For now, we'll store the linking information for later use in the link() function
    }

    pub fn build(self: *Builder, target_name: []const u8) !void {
        std.debug.print("Building target: {s}\n", .{target_name});

        const target = self.config.targets.get(target_name) orelse {
            std.debug.print("Error: Target '{s}' not found\n", .{target_name});
            return error.TargetNotFound;
        };

        try self.buildDependencyGraph(&target);

        if (try self.needsRebuild(&target)) {
            // First, build all Rust crates
            try self.buildRustCrates();

            // Then compile the main target sources
            try self.compileSources(&target);

            // Link everything together
            try self.link(&target);

            // Update cache
            try self.updateCache(&target);
            std.debug.print("Build complete: {s}\n", .{target.output});
        } else {
            std.debug.print("Target is up to date: {s}\n", .{target.output});
        }
    }

    fn buildRustCrates(self: *Builder) !void {
        if (self.rust_crates.count() == 0) return;

        std.debug.print("Building Rust crates...\n", .{});

        var crate_it = self.rust_crates.iterator();
        while (crate_it.next()) |entry| {
            const crate = entry.value_ptr;
            try self.buildRustCrate(crate);
        }
    }

    fn buildRustCrate(self: *Builder, crate: *RustCrate) !void {
        std.debug.print("  Building Rust crate: {s}\n", .{crate.name});

        // Set up environment for cross-compilation if needed
        const cross_compiling = crate.cross_compile != null;
        if (cross_compiling) {
            try self.setupRustCrossCompileEnvironment(crate);
            std.debug.print("    Cross-compiling for: {s}\n", .{crate.cross_compile.?.rust_target});
        }

        var argv = std.ArrayList([]const u8).init(self.allocator);
        defer argv.deinit();

        try argv.append("cargo");
        try argv.append("build");

        // Set optimization level
        switch (crate.optimize) {
            .Debug => {}, // cargo default is debug
            .ReleaseSafe, .ReleaseFast, .ReleaseSmall => try argv.append("--release"),
        }

        // Set target directory (include cross-compile target for isolation)
        const target_dir_name = if (cross_compiling)
            try std.fmt.allocPrint(self.allocator, "rust-target-{s}", .{crate.cross_compile.?.rust_target})
        else
            try self.allocator.dupe(u8, "rust-target");
        defer self.allocator.free(target_dir_name);

        const target_dir = try std.fs.path.join(self.allocator, &.{ self.build_dir, target_dir_name });
        defer self.allocator.free(target_dir);
        try argv.append("--target-dir");
        try argv.append(target_dir);

        // Add cross-compilation target
        if (crate.cross_compile) |cc| {
            try argv.append("--target");
            try argv.append(cc.rust_target);
        }

        // Add crate type if it's a library
        switch (crate.crate_type) {
            .cdylib, .staticlib => try argv.append("--lib"),
            .bin => {
                try argv.append("--bin");
                try argv.append(crate.name);
            },
            else => try argv.append("--lib"),
        }

        // Add features
        if (crate.features.items.len > 0) {
            try argv.append("--features");
            const features_str = try std.mem.join(self.allocator, ",", crate.features.items);
            defer self.allocator.free(features_str);
            try argv.append(features_str);
        }

        const result = try std.process.Child.run(.{
            .allocator = self.allocator,
            .argv = argv.items,
            .cwd = crate.path,
        });
        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);

        if (result.term.Exited != 0) {
            std.debug.print("Rust crate build failed:\n{s}\n", .{result.stderr});
            return error.RustCrateBuildFailed;
        }

        // Generate FFI headers if configured
        if (crate.ffi_headers != null) {
            try self.runCBindGen(crate);
        }

        const status_emoji = if (cross_compiling) "🌍" else "✅";
        std.debug.print("  {s} Rust crate built: {s}\n", .{ status_emoji, crate.name });
    }

    fn setupRustCrossCompileEnvironment(self: *Builder, crate: *RustCrate) !void {
        if (crate.cross_compile == null) return;
        const cc = crate.cross_compile.?;

        // Set linker environment variable if specified
        if (cc.linker) |linker| {
            const linker_env_var = try std.fmt.allocPrint(self.allocator, "CARGO_TARGET_{s}_LINKER", .{
                try self.rustTargetToEnvVar(cc.rust_target)
            });
            defer self.allocator.free(linker_env_var);

            try std.process.setEnvironmentVariable(linker_env_var, linker);
            std.debug.print("    Set {s}={s}\n", .{ linker_env_var, linker });
        }

        // Set sysroot if specified
        if (cc.sysroot) |sysroot| {
            const sysroot_env_var = try std.fmt.allocPrint(self.allocator, "CARGO_TARGET_{s}_RUSTFLAGS", .{
                try self.rustTargetToEnvVar(cc.rust_target)
            });
            defer self.allocator.free(sysroot_env_var);

            const rustflags = try std.fmt.allocPrint(self.allocator, "--sysroot={s}", .{sysroot});
            defer self.allocator.free(rustflags);

            try std.process.setEnvironmentVariable(sysroot_env_var, rustflags);
            std.debug.print("    Set {s}={s}\n", .{ sysroot_env_var, rustflags });
        }

        // Set any additional environment variables
        var env_it = cc.env_vars.iterator();
        while (env_it.next()) |entry| {
            try std.process.setEnvironmentVariable(entry.key_ptr.*, entry.value_ptr.*);
            std.debug.print("    Set {s}={s}\n", .{ entry.key_ptr.*, entry.value_ptr.* });
        }
    }

    fn rustTargetToEnvVar(self: *Builder, rust_target: []const u8) ![]const u8 {
        // Convert rust target triple to environment variable format
        // e.g., "x86_64-unknown-linux-gnu" -> "X86_64_UNKNOWN_LINUX_GNU"
        var result = try self.allocator.alloc(u8, rust_target.len);
        for (rust_target, 0..) |c, i| {
            result[i] = switch (c) {
                '-' => '_',
                'a'...'z' => c - 32, // Convert to uppercase
                else => c,
            };
        }
        return result;
    }

    // Utility function to convert Zig targets to Rust target triples
    pub fn zigTargetToRustTarget(self: *Builder, target: std.Target) ![]const u8 {
        const arch_str = switch (target.cpu.arch) {
            .x86 => "i686",
            .x86_64 => "x86_64",
            .arm => "arm",
            .aarch64 => "aarch64",
            .riscv32 => "riscv32gc",
            .riscv64 => "riscv64gc",
            .wasm32 => "wasm32",
            else => @tagName(target.cpu.arch),
        };

        const os_str = switch (target.os.tag) {
            .linux => "unknown-linux",
            .windows => "pc-windows",
            .macos => "apple-darwin",
            .freebsd => "unknown-freebsd",
            .wasi => "wasi",
            else => @tagName(target.os.tag),
        };

        const abi_str = switch (target.abi) {
            .gnu => "gnu",
            .musl => "musl",
            .msvc => "msvc",
            .none => "",
            else => @tagName(target.abi),
        };

        if (abi_str.len == 0) {
            return try std.fmt.allocPrint(self.allocator, "{s}-{s}", .{ arch_str, os_str });
        } else {
            return try std.fmt.allocPrint(self.allocator, "{s}-{s}-{s}", .{ arch_str, os_str, abi_str });
        }
    }

    // Multi-target build support - from the wishlist
    pub fn buildForTargets(self: *Builder, targets: []const std.Target) !void {
        std.debug.print("🌍 Building for {d} targets\n", .{targets.len});

        for (targets) |target| {
            const rust_target = try self.zigTargetToRustTarget(target);
            defer self.allocator.free(rust_target);

            std.debug.print("\n🔧 Building for target: {s}\n", .{rust_target});

            // Update all Rust crates to use this target
            var crate_it = self.rust_crates.iterator();
            while (crate_it.next()) |entry| {
                const crate = entry.value_ptr;

                // Set up cross-compilation config if not already set
                if (crate.cross_compile == null) {
                    crate.cross_compile = RustCrate.CrossCompileConfig{
                        .rust_target = try self.allocator.dupe(u8, rust_target),
                        .linker = null,
                        .sysroot = null,
                        .env_vars = std.StringHashMap([]const u8).init(self.allocator),
                    };
                }

                // Build the crate for this target
                try self.buildRustCrate(crate);
            }

            std.debug.print("✅ Target {s} complete\n", .{rust_target});
        }

        std.debug.print("\n🎉 Multi-target build complete!\n", .{});
    }

    fn buildDependencyGraph(self: *Builder, target: *const Config.Target) !void {
        var deps = std.ArrayList([]const u8){};

        for (target.dependencies.items) |dep| {
            try deps.append(self.allocator, dep);
        }

        try self.build_graph.put(target.name, deps);
    }

    fn needsRebuild(self: *Builder, target: *const Config.Target) !bool {
        const output_path = try std.fs.path.join(self.allocator, &.{ self.build_dir, target.output });
        defer self.allocator.free(output_path);

        const output_stat = std.fs.cwd().statFile(output_path) catch {
            return true;
        };

        for (target.sources.items) |source| {
            const source_stat = try std.fs.cwd().statFile(source);
            if (source_stat.mtime > output_stat.mtime) {
                return true;
            }
        }

        return false;
    }

    fn compileSources(self: *Builder, target: *const Config.Target) !void {
        // Using std.debug.print instead

        const has_rust = for (target.sources.items) |source| {
            if (std.mem.eql(u8, std.fs.path.extension(source), ".rs")) {
                break true;
            }
        } else false;

        if (has_rust) {
            try self.compileRustTarget(target);
            return;
        }

        for (target.sources.items) |source| {
            std.debug.print("  Compiling: {s}\n", .{source});

            const obj_name = try std.fmt.allocPrint(self.allocator, "{s}.o", .{std.fs.path.stem(source)});
            defer self.allocator.free(obj_name);

            const obj_path = try std.fs.path.join(self.allocator, &.{ self.build_dir, obj_name });
            defer self.allocator.free(obj_path);

            var argv = std.ArrayList([]const u8).init(self.allocator);
            defer argv.deinit();

            const ext = std.fs.path.extension(source);
            if (std.mem.eql(u8, ext, ".c")) {
                try argv.append("cc");
            } else if (std.mem.eql(u8, ext, ".cpp") or std.mem.eql(u8, ext, ".cc")) {
                try argv.append("c++");
            } else if (std.mem.eql(u8, ext, ".zig")) {
                try argv.append("zig");
                try argv.append("build-obj");
            } else {
                continue;
            }

            try argv.append("-c");
            try argv.append(source);
            try argv.append("-o");
            try argv.append(obj_path);

            for (self.config.compiler_flags.items) |flag| {
                try argv.append(flag);
            }

            for (target.flags.items) |flag| {
                try argv.append(flag);
            }

            const result = try std.process.Child.run(.{
                .allocator = self.allocator,
                .argv = argv.items,
            });
            defer self.allocator.free(result.stdout);
            defer self.allocator.free(result.stderr);

            if (result.term.Exited != 0) {
                std.debug.print("Compilation failed:\n{s}\n", .{result.stderr});
                return error.CompilationFailed;
            }
        }
    }

    fn compileRustTarget(self: *Builder, target: *const Config.Target) !void {
        std.debug.print("  Compiling Rust target: {s}\n", .{target.name});

        // First try to use cargo if Cargo.toml exists
        if (self.hasCargoToml(target)) {
            try self.compileWithCargo(target);
        } else {
            try self.compileWithRustc(target);
        }

        std.debug.print("  Rust compilation complete: {s}\n", .{target.output});
    }

    fn hasCargoToml(self: *Builder, target: *const Config.Target) bool {
        // Check for Cargo.toml in the target sources directory
        for (target.sources.items) |source| {
            const dir = std.fs.path.dirname(source) orelse ".";
            const cargo_path = std.fs.path.join(self.allocator, &.{ dir, "Cargo.toml" }) catch continue;
            defer self.allocator.free(cargo_path);

            const file = std.fs.cwd().openFile(cargo_path, .{}) catch continue;
            file.close();
            return true;
        }

        return false;
    }

    fn compileWithCargo(self: *Builder, target: *const Config.Target) !void {
        var argv = std.ArrayList([]const u8).init(self.allocator);
        defer argv.deinit();

        try argv.append("cargo");
        try argv.append("build");
        try argv.append("--release");

        // Add target directory
        const target_dir = try std.fs.path.join(self.allocator, &.{ self.build_dir, "rust-target" });
        defer self.allocator.free(target_dir);
        try argv.append("--target-dir");
        try argv.append(target_dir);

        // Set crate type based on target type
        switch (target.type) {
            .static_library => {
                try argv.append("--lib");
            },
            .dynamic_library => {
                try argv.append("--lib");
            },
            .executable => {
                try argv.append("--bin");
                try argv.append(target.name);
            },
            else => {},
        }

        // Add features if any
        if (target.flags.items.len > 0) {
            var features = std.ArrayList([]const u8).init(self.allocator);
            defer features.deinit();

            for (target.flags.items) |flag| {
                if (std.mem.startsWith(u8, flag, "--features=")) {
                    const feature_list = flag[11..];
                    try features.append(feature_list);
                }
            }

            if (features.items.len > 0) {
                try argv.append("--features");
                const feature_str = try std.mem.join(self.allocator, ",", features.items);
                defer self.allocator.free(feature_str);
                try argv.append(feature_str);
            }
        }

        const result = try std.process.Child.run(.{
            .allocator = self.allocator,
            .argv = argv.items,
        });
        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);

        if (result.term.Exited != 0) {
            std.debug.print("Cargo build failed:\n{s}\n", .{result.stderr});
            return error.CargoBuildFailed;
        }

        // Copy the built artifact to our build directory
        try self.copyRustArtifact(target, target_dir);
    }

    fn compileWithRustc(self: *Builder, target: *const Config.Target) !void {
        var argv = std.ArrayList([]const u8).init(self.allocator);
        defer argv.deinit();

        try argv.append("rustc");

        const main_source = for (target.sources.items) |source| {
            if (std.mem.endsWith(u8, source, "main.rs") or std.mem.endsWith(u8, source, "lib.rs")) {
                break source;
            }
        } else target.sources.items[0];

        try argv.append(main_source);

        const output_path = try std.fs.path.join(self.allocator, &.{ self.build_dir, target.output });
        defer self.allocator.free(output_path);

        try argv.append("-o");
        try argv.append(output_path);

        switch (target.type) {
            .static_library => try argv.append("--crate-type=staticlib"),
            .dynamic_library => try argv.append("--crate-type=cdylib"),
            .executable => try argv.append("--crate-type=bin"),
            else => {},
        }

        try argv.append("-C");
        try argv.append("opt-level=2");
        try argv.append("-C");
        try argv.append("target-cpu=native");
        try argv.append("-L");
        try argv.append(self.build_dir);

        for (target.flags.items) |flag| {
            try argv.append(flag);
        }

        const result = try std.process.Child.run(.{
            .allocator = self.allocator,
            .argv = argv.items,
        });
        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);

        if (result.term.Exited != 0) {
            std.debug.print("Rust compilation failed:\n{s}\n", .{result.stderr});
            return error.RustCompilationFailed;
        }
    }

    fn copyRustArtifact(self: *Builder, target: *const Config.Target, target_dir: []const u8) !void {
        var source_path: []const u8 = undefined;
        const target_path = try std.fs.path.join(self.allocator, &.{ self.build_dir, target.output });
        defer self.allocator.free(target_path);

        switch (target.type) {
            .static_library => {
                source_path = try std.fs.path.join(self.allocator, &.{ target_dir, "release", "deps", "lib" ++ target.name ++ ".a" });
            },
            .dynamic_library => {
                source_path = try std.fs.path.join(self.allocator, &.{ target_dir, "release", "deps", "lib" ++ target.name ++ ".so" });
            },
            .executable => {
                source_path = try std.fs.path.join(self.allocator, &.{ target_dir, "release", target.name });
            },
            else => return,
        }
        defer self.allocator.free(source_path);

        try std.fs.cwd().copyFile(source_path, std.fs.cwd(), target_path, .{});
        std.debug.print("  Copied artifact: {s} -> {s}\n", .{ source_path, target_path });
    }

    fn link(self: *Builder, target: *const Config.Target) !void {
        const has_rust = for (target.sources.items) |source| {
            if (std.mem.eql(u8, std.fs.path.extension(source), ".rs")) {
                break true;
            }
        } else false;

        if (has_rust) {
            // Rust targets are already built and linked by cargo
            return;
        }

        std.debug.print("  Linking: {s}\n", .{target.output});

        const output_path = try std.fs.path.join(self.allocator, &.{ self.build_dir, target.output });
        defer self.allocator.free(output_path);

        var argv = std.ArrayList([]const u8).init(self.allocator);
        defer argv.deinit();

        try argv.append("cc");

        var objects = std.ArrayList([]const u8).init(self.allocator);
        defer objects.deinit();

        // Add object files from sources
        for (target.sources.items) |source| {
            const obj_name = try std.fmt.allocPrint(self.allocator, "{s}.o", .{std.fs.path.stem(source)});
            const obj_path = try std.fs.path.join(self.allocator, &.{ self.build_dir, obj_name });
            try objects.append(self.allocator, obj_path);
            try argv.append(obj_path);
        }

        try argv.append("-o");
        try argv.append(output_path);

        // Add Rust library linking
        if (self.rust_crates.count() > 0) {
            try self.addRustLibrariesLinkedToArg(&argv);
        }

        switch (target.type) {
            .static_library => {
                argv.items[0] = "ar";
                try argv.insert(1, "rcs");
            },
            .dynamic_library => {
                try argv.append("-shared");
                try argv.append("-fPIC");
            },
            else => {},
        }

        for (self.config.linker_flags.items) |flag| {
            try argv.append(flag);
        }

        const result = try std.process.Child.run(.{
            .allocator = self.allocator,
            .argv = argv.items,
        });
        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);

        if (result.term.Exited != 0) {
            std.debug.print("Linking failed:\n{s}\n", .{result.stderr});
            return error.LinkingFailed;
        }

        for (objects.items) |obj| {
            self.allocator.free(obj);
        }
    }

    fn addRustLibrariesLinkedToArg(self: *Builder, argv: *std.ArrayList([]const u8)) !void {
        // Add library search path for Rust libraries
        const rust_lib_path = try std.fs.path.join(self.allocator, &.{ self.build_dir, "rust-target", "release" });
        defer self.allocator.free(rust_lib_path);

        try argv.append("-L");
        try argv.append(rust_lib_path);

        // Add each Rust crate as a library
        var crate_it = self.rust_crates.iterator();
        while (crate_it.next()) |entry| {
            const crate = entry.value_ptr;

            switch (crate.crate_type) {
                .cdylib, .staticlib => {
                    // Link the library
                    const link_arg = try std.fmt.allocPrint(self.allocator, "-l{s}", .{crate.name});
                    defer self.allocator.free(link_arg);
                    try argv.append(try self.allocator.dupe(u8, link_arg));

                    std.debug.print("    Linking Rust library: {s}\n", .{crate.name});
                },
                else => {},
            }
        }

        // Add system dependencies that Rust might need
        try argv.append("-ldl");   // Dynamic loading
        try argv.append("-lpthread"); // Threading
        try argv.append("-lm");    // Math library
    }

    fn updateCache(self: *Builder, target: *const Config.Target) !void {
        const output_path = try std.fs.path.join(self.allocator, &.{ self.build_dir, target.output });
        defer self.allocator.free(output_path);

        const file = try std.fs.cwd().openFile(output_path, .{});
        defer file.close();

        const stat = try file.stat();
        var hasher = std.crypto.hash.sha2.Sha256.init(.{});

        const content = try self.allocator.alloc(u8, stat.size);
        defer self.allocator.free(content);

        _ = try file.readAll(content);
        hasher.update(content);

        var hash: [32]u8 = undefined;
        hasher.final(&hash);

        const artifact = Artifact{
            .path = try self.allocator.dupe(u8, output_path),
            .timestamp = stat.mtime,
            .hash = hash,
        };

        try self.artifacts.put(target.name, artifact);
        try self.cache.store(target.name, &artifact, @sizeOf(Artifact));
    }

    pub fn runTests(self: *Builder, target_name: []const u8) !void {
        // Using std.debug.print instead
        std.debug.print("Running tests for target: {s}\n", .{target_name});

        try self.build(target_name);

        const target = self.config.targets.get(target_name) orelse {
            return error.TargetNotFound;
        };

        const output_path = try std.fs.path.join(self.allocator, &.{ self.build_dir, target.output });
        defer self.allocator.free(output_path);

        const result = try std.process.Child.run(.{
            .allocator = self.allocator,
            .argv = &.{output_path},
        });
        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);

        std.debug.print("{s}\n", .{result.stdout});
        if (result.stderr.len > 0) {
            std.debug.print("{s}\n", .{result.stderr});
        }

        if (result.term.Exited != 0) {
            return error.TestsFailed;
        }
    }
};