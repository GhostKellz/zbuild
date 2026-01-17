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
    io: std.Io,

    const Artifact = struct {
        path: []const u8,
        timestamp: i128,
        hash: [32]u8,
    };

    pub const RustCrate = struct {
        allocator: std.mem.Allocator,
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
                .allocator = allocator,
                .name = name,
                .path = path,
                .crate_type = .lib,
                .features = .empty,
                .target = null,
                .optimize = .ReleaseFast,
                .ffi_headers = null,
                .cross_compile = null,
            };
        }

        pub fn deinit(self: *RustCrate) void {
            self.features.deinit(self.allocator);
            if (self.cross_compile) |*cc| {
                cc.env_vars.deinit();
            }
        }
    };

    pub fn init(allocator: std.mem.Allocator, config: *const Config, io: std.Io) !Builder {
        const build_dir = try std.Io.Dir.path.join(allocator, &.{ ".zbuild", "build" });
        try makePath(allocator, build_dir);

        return .{
            .allocator = allocator,
            .config = config,
            .cache = try Cache.init(allocator, ".zbuild"),
            .build_dir = build_dir,
            .artifacts = std.StringHashMap(Artifact).init(allocator),
            .build_graph = std.StringHashMap(std.ArrayList([]const u8)).init(allocator),
            .rust_crates = std.StringHashMap(RustCrate).init(allocator),
            .cross_compile = CrossCompile.init(allocator),
            .io = io,
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

    /// Helper to copy a file using Linux syscalls
    fn copyFile(allocator: std.mem.Allocator, source: []const u8, dest: []const u8) !void {
        // Open source file
        const src_fd = try std.posix.openat(std.posix.AT.FDCWD, source, .{}, 0);
        defer std.posix.close(src_fd);

        // Create destination file
        const dst_fd = try std.posix.openat(std.posix.AT.FDCWD, dest, .{ .CREAT = true, .TRUNC = true, .ACCMODE = .WRONLY }, 0o644);
        defer std.posix.close(dst_fd);

        // Copy in chunks
        var buf: [8192]u8 = undefined;
        while (true) {
            const bytes_read = try std.posix.read(src_fd, &buf);
            if (bytes_read == 0) break;

            var written: usize = 0;
            while (written < bytes_read) {
                const result = std.os.linux.write(dst_fd, buf[written..bytes_read].ptr, bytes_read - written);
                const err = std.posix.errno(result);
                if (err != .SUCCESS) {
                    return error.WriteFailed;
                }
                written += result;
            }
        }

        _ = allocator; // allocator not needed but kept for consistency
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
        try makePath(self.allocator, options.output_dir);

        // Run cbindgen to generate headers
        try self.runCBindGen(crate);
    }

    fn runCBindGen(self: *Builder, crate: *RustCrate) !void {
        if (crate.ffi_headers == null) return;

        const ffi_config = crate.ffi_headers.?;
        const header_path = try std.Io.Dir.path.join(self.allocator, &.{ ffi_config.output_dir, ffi_config.header_name });
        defer self.allocator.free(header_path);

        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(self.allocator);

        try argv.append(self.allocator, "cbindgen");
        try argv.append(self.allocator, "--crate");
        try argv.append(self.allocator, crate.name);
        try argv.append(self.allocator, "--output");
        try argv.append(self.allocator, header_path);
        try argv.append(self.allocator, "--lang");
        try argv.append(self.allocator, "c");

        if (ffi_config.include_guard) |guard| {
            try argv.append(self.allocator, "--cpp-compat");
            try argv.append(self.allocator, "--include-guard");
            try argv.append(self.allocator, guard);
        }

        const result = try self.runProcess(argv.items, crate.path);
        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);

        switch (result.term) {
            .exited => |code| if (code != 0) {
                std.debug.print("cbindgen failed:\n{s}\n", .{result.stderr});
                return error.CBindGenFailed;
            },
            else => {
                std.debug.print("cbindgen failed:\n{s}\n", .{result.stderr});
                return error.CBindGenFailed;
            },
        }

        std.debug.print("Generated FFI headers: {s}\n", .{header_path});
    }

    // Link a Rust crate to a Zig executable - from the wishlist API
    pub fn linkRustCrate(self: *Builder, executable: anytype, rust_crate: *RustCrate) !void {
        _ = executable; // Will be used in actual implementation

        // Add library search path
        const lib_path = try std.Io.Dir.path.join(self.allocator, &.{ self.build_dir, "rust-target", "release" });
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

        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(self.allocator);

        try argv.append(self.allocator, "cargo");
        try argv.append(self.allocator, "build");

        // Set optimization level
        switch (crate.optimize) {
            .Debug => {}, // cargo default is debug
            .ReleaseSafe, .ReleaseFast, .ReleaseSmall => try argv.append(self.allocator, "--release"),
        }

        // Set target directory (include cross-compile target for isolation)
        const target_dir_name = if (cross_compiling)
            try std.fmt.allocPrint(self.allocator, "rust-target-{s}", .{crate.cross_compile.?.rust_target})
        else
            try self.allocator.dupe(u8, "rust-target");
        defer self.allocator.free(target_dir_name);

        const target_dir = try std.Io.Dir.path.join(self.allocator, &.{ self.build_dir, target_dir_name });
        defer self.allocator.free(target_dir);
        try argv.append(self.allocator, "--target-dir");
        try argv.append(self.allocator, target_dir);

        // Add cross-compilation target
        if (crate.cross_compile) |cc| {
            try argv.append(self.allocator, "--target");
            try argv.append(self.allocator, cc.rust_target);
        }

        // Add crate type if it's a library
        switch (crate.crate_type) {
            .cdylib, .staticlib => try argv.append(self.allocator, "--lib"),
            .bin => {
                try argv.append(self.allocator, "--bin");
                try argv.append(self.allocator, crate.name);
            },
            else => try argv.append(self.allocator, "--lib"),
        }

        // Add features
        if (crate.features.items.len > 0) {
            try argv.append(self.allocator, "--features");
            const features_str = try std.mem.join(self.allocator, ",", crate.features.items);
            defer self.allocator.free(features_str);
            try argv.append(self.allocator, features_str);
        }

        const result = try self.runProcess(argv.items, crate.path);
        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);

        switch (result.term) {
            .exited => |code| if (code != 0) {
                std.debug.print("Rust crate build failed:\n{s}\n", .{result.stderr});
                return error.RustCrateBuildFailed;
            },
            else => {
                std.debug.print("Rust crate build failed:\n{s}\n", .{result.stderr});
                return error.RustCrateBuildFailed;
            },
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

        // Note: In Zig 0.16.0-dev, setEnvironmentVariable is no longer available.
        // Users must set these environment variables externally before running the build.
        std.debug.print("    Cross-compilation environment (set these manually if not already set):\n", .{});

        // Print linker environment variable if specified
        if (cc.linker) |linker| {
            const linker_env_var = try std.fmt.allocPrint(self.allocator, "CARGO_TARGET_{s}_LINKER", .{
                try self.rustTargetToEnvVar(cc.rust_target)
            });
            defer self.allocator.free(linker_env_var);

            std.debug.print("      {s}={s}\n", .{ linker_env_var, linker });
        }

        // Print sysroot if specified
        if (cc.sysroot) |sysroot| {
            const sysroot_env_var = try std.fmt.allocPrint(self.allocator, "CARGO_TARGET_{s}_RUSTFLAGS", .{
                try self.rustTargetToEnvVar(cc.rust_target)
            });
            defer self.allocator.free(sysroot_env_var);

            const rustflags = try std.fmt.allocPrint(self.allocator, "--sysroot={s}", .{sysroot});
            defer self.allocator.free(rustflags);

            std.debug.print("      {s}={s}\n", .{ sysroot_env_var, rustflags });
        }

        // Print any additional environment variables
        var env_it = cc.env_vars.iterator();
        while (env_it.next()) |entry| {
            std.debug.print("      {s}={s}\n", .{ entry.key_ptr.*, entry.value_ptr.* });
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
        var deps: std.ArrayList([]const u8) = .empty;

        for (target.dependencies.items) |dep| {
            try deps.append(self.allocator, dep);
        }

        try self.build_graph.put(target.name, deps);
    }

    fn needsRebuild(self: *Builder, target: *const Config.Target) !bool {
        const output_path = try std.Io.Dir.path.join(self.allocator, &.{ self.build_dir, target.output });
        defer self.allocator.free(output_path);

        const output_mtime = getFileMtime(self.allocator, output_path) catch {
            return true;
        };

        for (target.sources.items) |source| {
            const source_mtime = try getFileMtime(self.allocator, source);
            if (source_mtime > output_mtime) {
                return true;
            }
        }

        return false;
    }

    /// Helper to get file modification time using Linux statx syscall
    fn getFileMtime(allocator: std.mem.Allocator, path: []const u8) !i128 {
        // Create null-terminated path
        const path_with_null = try allocator.alloc(u8, path.len + 1);
        defer allocator.free(path_with_null);
        @memcpy(path_with_null[0..path.len], path);
        path_with_null[path.len] = 0;
        const path_z: [*:0]const u8 = @ptrCast(path_with_null.ptr);

        var statx_buf: std.os.linux.Statx = undefined;
        const result = std.os.linux.statx(
            std.posix.AT.FDCWD,
            path_z,
            0,
            @bitCast(std.os.linux.STATX{ .MTIME = true }),
            &statx_buf,
        );

        const err = std.posix.errno(result);
        if (err != .SUCCESS) {
            return error.StatFailed;
        }

        // Convert to nanosecond timestamp
        return @as(i128, statx_buf.mtime.sec) * std.time.ns_per_s + statx_buf.mtime.nsec;
    }

    fn compileSources(self: *Builder, target: *const Config.Target) !void {
        // Using std.debug.print instead

        const has_rust = for (target.sources.items) |source| {
            if (std.mem.eql(u8, std.Io.Dir.path.extension(source), ".rs")) {
                break true;
            }
        } else false;

        if (has_rust) {
            try self.compileRustTarget(target);
            return;
        }

        for (target.sources.items) |source| {
            std.debug.print("  Compiling: {s}\n", .{source});

            const obj_name = try std.fmt.allocPrint(self.allocator, "{s}.o", .{std.Io.Dir.path.stem(source)});
            defer self.allocator.free(obj_name);

            const obj_path = try std.Io.Dir.path.join(self.allocator, &.{ self.build_dir, obj_name });
            defer self.allocator.free(obj_path);

            var argv: std.ArrayList([]const u8) = .empty;
            defer argv.deinit(self.allocator);

            const ext = std.Io.Dir.path.extension(source);
            if (std.mem.eql(u8, ext, ".c")) {
                try argv.append(self.allocator, "cc");
            } else if (std.mem.eql(u8, ext, ".cpp") or std.mem.eql(u8, ext, ".cc")) {
                try argv.append(self.allocator, "c++");
            } else if (std.mem.eql(u8, ext, ".zig")) {
                try argv.append(self.allocator, "zig");
                try argv.append(self.allocator, "build-obj");
            } else {
                continue;
            }

            try argv.append(self.allocator, "-c");
            try argv.append(self.allocator, source);
            try argv.append(self.allocator, "-o");
            try argv.append(self.allocator, obj_path);

            for (self.config.compiler_flags.items) |flag| {
                try argv.append(self.allocator, flag);
            }

            for (target.flags.items) |flag| {
                try argv.append(self.allocator, flag);
            }

            const result = try self.runProcess(argv.items, null);
            defer self.allocator.free(result.stdout);
            defer self.allocator.free(result.stderr);

            switch (result.term) {
                .exited => |code| if (code != 0) {
                    std.debug.print("Compilation failed:\n{s}\n", .{result.stderr});
                    return error.CompilationFailed;
                },
                else => {
                    std.debug.print("Compilation failed:\n{s}\n", .{result.stderr});
                    return error.CompilationFailed;
                },
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
            const dir = std.Io.Dir.path.dirname(source) orelse ".";
            const cargo_path = std.Io.Dir.path.join(self.allocator, &.{ dir, "Cargo.toml" }) catch continue;
            defer self.allocator.free(cargo_path);

            const file = std.posix.openat(std.posix.AT.FDCWD, cargo_path, .{}, 0) catch continue;
            std.posix.close(file);
            return true;
        }

        return false;
    }

    fn compileWithCargo(self: *Builder, target: *const Config.Target) !void {
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(self.allocator);

        try argv.append(self.allocator, "cargo");
        try argv.append(self.allocator, "build");
        try argv.append(self.allocator, "--release");

        // Add target directory
        const target_dir = try std.Io.Dir.path.join(self.allocator, &.{ self.build_dir, "rust-target" });
        defer self.allocator.free(target_dir);
        try argv.append(self.allocator, "--target-dir");
        try argv.append(self.allocator, target_dir);

        // Set crate type based on target type
        switch (target.type) {
            .static_library => {
                try argv.append(self.allocator, "--lib");
            },
            .dynamic_library => {
                try argv.append(self.allocator, "--lib");
            },
            .executable => {
                try argv.append(self.allocator, "--bin");
                try argv.append(self.allocator, target.name);
            },
            else => {},
        }

        // Add features if any
        if (target.flags.items.len > 0) {
            var features: std.ArrayList([]const u8) = .empty;
            defer features.deinit(self.allocator);

            for (target.flags.items) |flag| {
                if (std.mem.startsWith(u8, flag, "--features=")) {
                    const feature_list = flag[11..];
                    try features.append(self.allocator, feature_list);
                }
            }

            if (features.items.len > 0) {
                try argv.append(self.allocator, "--features");
                const feature_str = try std.mem.join(self.allocator, ",", features.items);
                defer self.allocator.free(feature_str);
                try argv.append(self.allocator, feature_str);
            }
        }

        const result = try self.runProcess(argv.items, null);
        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);

        switch (result.term) {
            .exited => |code| if (code != 0) {
                std.debug.print("Cargo build failed:\n{s}\n", .{result.stderr});
                return error.CargoBuildFailed;
            },
            else => {
                std.debug.print("Cargo build failed:\n{s}\n", .{result.stderr});
                return error.CargoBuildFailed;
            },
        }

        // Copy the built artifact to our build directory
        try self.copyRustArtifact(target, target_dir);
    }

    fn compileWithRustc(self: *Builder, target: *const Config.Target) !void {
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(self.allocator);

        try argv.append(self.allocator, "rustc");

        const main_source = for (target.sources.items) |source| {
            if (std.mem.endsWith(u8, source, "main.rs") or std.mem.endsWith(u8, source, "lib.rs")) {
                break source;
            }
        } else target.sources.items[0];

        try argv.append(self.allocator, main_source);

        const output_path = try std.Io.Dir.path.join(self.allocator, &.{ self.build_dir, target.output });
        defer self.allocator.free(output_path);

        try argv.append(self.allocator, "-o");
        try argv.append(self.allocator, output_path);

        switch (target.type) {
            .static_library => try argv.append(self.allocator, "--crate-type=staticlib"),
            .dynamic_library => try argv.append(self.allocator, "--crate-type=cdylib"),
            .executable => try argv.append(self.allocator, "--crate-type=bin"),
            else => {},
        }

        try argv.append(self.allocator, "-C");
        try argv.append(self.allocator, "opt-level=2");
        try argv.append(self.allocator, "-C");
        try argv.append(self.allocator, "target-cpu=native");
        try argv.append(self.allocator, "-L");
        try argv.append(self.allocator, self.build_dir);

        for (target.flags.items) |flag| {
            try argv.append(self.allocator, flag);
        }

        const result = try self.runProcess(argv.items, null);
        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);

        switch (result.term) {
            .exited => |code| if (code != 0) {
                std.debug.print("Rust compilation failed:\n{s}\n", .{result.stderr});
                return error.RustCompilationFailed;
            },
            else => {
                std.debug.print("Rust compilation failed:\n{s}\n", .{result.stderr});
                return error.RustCompilationFailed;
            },
        }
    }

    fn copyRustArtifact(self: *Builder, target: *const Config.Target, target_dir: []const u8) !void {
        var source_path: []const u8 = undefined;
        const target_path = try std.Io.Dir.path.join(self.allocator, &.{ self.build_dir, target.output });
        defer self.allocator.free(target_path);

        switch (target.type) {
            .static_library => {
                const lib_name = try std.fmt.allocPrint(self.allocator, "lib{s}.a", .{target.name});
                defer self.allocator.free(lib_name);
                source_path = try std.Io.Dir.path.join(self.allocator, &.{ target_dir, "release", "deps", lib_name });
            },
            .dynamic_library => {
                const lib_name = try std.fmt.allocPrint(self.allocator, "lib{s}.so", .{target.name});
                defer self.allocator.free(lib_name);
                source_path = try std.Io.Dir.path.join(self.allocator, &.{ target_dir, "release", "deps", lib_name });
            },
            .executable => {
                source_path = try std.Io.Dir.path.join(self.allocator, &.{ target_dir, "release", target.name });
            },
            else => return,
        }
        defer self.allocator.free(source_path);

        try copyFile(self.allocator, source_path, target_path);
        std.debug.print("  Copied artifact: {s} -> {s}\n", .{ source_path, target_path });
    }

    fn link(self: *Builder, target: *const Config.Target) !void {
        const has_rust = for (target.sources.items) |source| {
            if (std.mem.eql(u8, std.Io.Dir.path.extension(source), ".rs")) {
                break true;
            }
        } else false;

        if (has_rust) {
            // Rust targets are already built and linked by cargo
            return;
        }

        std.debug.print("  Linking: {s}\n", .{target.output});

        const output_path = try std.Io.Dir.path.join(self.allocator, &.{ self.build_dir, target.output });
        defer self.allocator.free(output_path);

        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(self.allocator);

        try argv.append(self.allocator, "cc");

        var objects: std.ArrayList([]const u8) = .empty;
        defer objects.deinit(self.allocator);

        // Add object files from sources
        for (target.sources.items) |source| {
            const obj_name = try std.fmt.allocPrint(self.allocator, "{s}.o", .{std.Io.Dir.path.stem(source)});
            const obj_path = try std.Io.Dir.path.join(self.allocator, &.{ self.build_dir, obj_name });
            try objects.append(self.allocator, obj_path);
            try argv.append(self.allocator, obj_path);
        }

        try argv.append(self.allocator, "-o");
        try argv.append(self.allocator, output_path);

        // Add Rust library linking
        if (self.rust_crates.count() > 0) {
            try self.addRustLibrariesLinkedToArg(&argv);
        }

        switch (target.type) {
            .static_library => {
                argv.items[0] = "ar";
                try argv.insert(self.allocator, 1, "rcs");
            },
            .dynamic_library => {
                try argv.append(self.allocator, "-shared");
                try argv.append(self.allocator, "-fPIC");
            },
            else => {},
        }

        for (self.config.linker_flags.items) |flag| {
            try argv.append(self.allocator, flag);
        }

        const result = try self.runProcess(argv.items, null);
        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);

        switch (result.term) {
            .exited => |code| if (code != 0) {
                std.debug.print("Linking failed:\n{s}\n", .{result.stderr});
                return error.LinkingFailed;
            },
            else => {
                std.debug.print("Linking failed:\n{s}\n", .{result.stderr});
                return error.LinkingFailed;
            },
        }

        for (objects.items) |obj| {
            self.allocator.free(obj);
        }
    }

    fn addRustLibrariesLinkedToArg(self: *Builder, argv: *std.ArrayList([]const u8)) !void {
        // Add library search path for Rust libraries
        const rust_lib_path = try std.Io.Dir.path.join(self.allocator, &.{ self.build_dir, "rust-target", "release" });
        defer self.allocator.free(rust_lib_path);

        try argv.append(self.allocator, "-L");
        try argv.append(self.allocator, rust_lib_path);

        // Add each Rust crate as a library
        var crate_it = self.rust_crates.iterator();
        while (crate_it.next()) |entry| {
            const crate = entry.value_ptr;

            switch (crate.crate_type) {
                .cdylib, .staticlib => {
                    // Link the library
                    const link_arg = try std.fmt.allocPrint(self.allocator, "-l{s}", .{crate.name});
                    defer self.allocator.free(link_arg);
                    try argv.append(self.allocator, try self.allocator.dupe(u8, link_arg));

                    std.debug.print("    Linking Rust library: {s}\n", .{crate.name});
                },
                else => {},
            }
        }

        // Add system dependencies that Rust might need
        try argv.append(self.allocator, "-ldl");   // Dynamic loading
        try argv.append(self.allocator, "-lpthread"); // Threading
        try argv.append(self.allocator, "-lm");    // Math library
    }

    fn updateCache(self: *Builder, target: *const Config.Target) !void {
        const output_path = try std.Io.Dir.path.join(self.allocator, &.{ self.build_dir, target.output });
        defer self.allocator.free(output_path);

        const file = try std.posix.openat(std.posix.AT.FDCWD, output_path, .{}, 0);
        defer std.posix.close(file);

        var hasher = std.crypto.hash.sha2.Sha256.init(.{});

        // Read file in chunks and hash
        var buf: [4096]u8 = undefined;
        var total_size: usize = 0;
        while (true) {
            const bytes_read = try std.posix.read(file, &buf);
            if (bytes_read == 0) break;
            hasher.update(buf[0..bytes_read]);
            total_size += bytes_read;
        }

        var hash: [32]u8 = undefined;
        hasher.final(&hash);

        // Get file mtime for the artifact
        const mtime = getFileMtime(self.allocator, output_path) catch blk: {
            // Fallback: use current time
            const ts = std.posix.clock_gettime(std.posix.CLOCK.REALTIME) catch break :blk 0;
            break :blk @as(i128, ts.sec) * std.time.ns_per_s + ts.nsec;
        };

        const artifact = Artifact{
            .path = try self.allocator.dupe(u8, output_path),
            .timestamp = mtime,
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

        const output_path = try std.Io.Dir.path.join(self.allocator, &.{ self.build_dir, target.output });
        defer self.allocator.free(output_path);

        const result = try self.runProcess(&.{output_path}, null);
        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);

        std.debug.print("{s}\n", .{result.stdout});
        if (result.stderr.len > 0) {
            std.debug.print("{s}\n", .{result.stderr});
        }

        switch (result.term) {
            .exited => |code| if (code != 0) return error.TestsFailed,
            else => return error.TestsFailed,
        }
    }

    fn runProcess(self: *Builder, argv: []const []const u8, cwd: ?[]const u8) !std.process.RunResult {
        return std.process.run(self.allocator, self.io, .{ .argv = argv, .cwd = cwd });
    }
};