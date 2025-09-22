const std = @import("std");

pub const CrossCompile = struct {
    allocator: std.mem.Allocator,
    targets: std.StringHashMap(TargetConfig),
    toolchains: std.StringHashMap(Toolchain),

    pub const TargetConfig = struct {
        arch: Arch,
        os: Os,
        abi: Abi,
        cpu_features: std.ArrayList([]const u8),
        sysroot: ?[]const u8,
    };

    pub const Arch = enum {
        x86,
        x86_64,
        arm,
        aarch64,
        riscv32,
        riscv64,
        wasm32,
        wasm64,
        mips,
        mips64,
        powerpc,
        powerpc64,
    };

    pub const Os = enum {
        linux,
        windows,
        macos,
        freebsd,
        openbsd,
        netbsd,
        dragonfly,
        android,
        ios,
        wasi,
        emscripten,
        freestanding,
    };

    pub const Abi = enum {
        none,
        gnu,
        gnueabi,
        gnueabihf,
        musl,
        msvc,
        android,
        macho,
        wasi,
    };

    pub const Toolchain = struct {
        name: []const u8,
        compiler: []const u8,
        linker: []const u8,
        archiver: []const u8,
        sysroot: ?[]const u8,
        flags: std.ArrayList([]const u8),
        env_vars: std.StringHashMap([]const u8),
    };

    pub fn init(allocator: std.mem.Allocator) CrossCompile {
        return .{
            .allocator = allocator,
            .targets = std.StringHashMap(TargetConfig).init(allocator),
            .toolchains = std.StringHashMap(Toolchain).init(allocator),
        };
    }

    pub fn deinit(self: *CrossCompile) void {
        var target_it = self.targets.iterator();
        while (target_it.next()) |entry| {
            entry.value_ptr.cpu_features.deinit();
        }
        self.targets.deinit();

        var toolchain_it = self.toolchains.iterator();
        while (toolchain_it.next()) |entry| {
            entry.value_ptr.flags.deinit();
            entry.value_ptr.env_vars.deinit();
        }
        self.toolchains.deinit();
    }

    pub fn addTarget(self: *CrossCompile, name: []const u8, config: TargetConfig) !void {
        try self.targets.put(name, config);
        try self.detectToolchain(&config);
    }

    pub fn detectToolchain(self: *CrossCompile, target: *const TargetConfig) !void {
        const triple = try self.getTargetTriple(target);
        defer self.allocator.free(triple);

        var toolchain = Toolchain{
            .name = try self.allocator.dupe(u8, triple),
            .compiler = try self.getCompilerForTarget(target),
            .linker = try self.getLinkerForTarget(target),
            .archiver = try self.getArchiverForTarget(target),
            .sysroot = target.sysroot,
            .flags = std.ArrayList([]const u8).init(self.allocator),
            .env_vars = std.StringHashMap([]const u8).init(self.allocator),
        };

        try self.addDefaultFlags(&toolchain, target);
        try self.toolchains.put(triple, toolchain);
    }

    pub fn getTargetTriple(self: *CrossCompile, target: *const TargetConfig) ![]const u8 {
        const arch_str = @tagName(target.arch);
        const os_str = @tagName(target.os);
        const abi_str = @tagName(target.abi);

        if (target.abi == .none) {
            return try std.fmt.allocPrint(self.allocator, "{s}-{s}", .{ arch_str, os_str });
        } else {
            return try std.fmt.allocPrint(self.allocator, "{s}-{s}-{s}", .{ arch_str, os_str, abi_str });
        }
    }

    fn getCompilerForTarget(self: *CrossCompile, target: *const TargetConfig) ![]const u8 {
        const triple = try self.getTargetTriple(target);
        defer self.allocator.free(triple);

        const gcc_name = try std.fmt.allocPrint(self.allocator, "{s}-gcc", .{triple});
        if (self.findExecutable(gcc_name)) {
            return gcc_name;
        }
        self.allocator.free(gcc_name);

        const clang_name = try std.fmt.allocPrint(self.allocator, "{s}-clang", .{triple});
        if (self.findExecutable(clang_name)) {
            return clang_name;
        }
        self.allocator.free(clang_name);

        return try self.allocator.dupe(u8, "clang");
    }

    fn getLinkerForTarget(self: *CrossCompile, target: *const TargetConfig) ![]const u8 {
        const triple = try self.getTargetTriple(target);
        defer self.allocator.free(triple);

        const ld_name = try std.fmt.allocPrint(self.allocator, "{s}-ld", .{triple});
        if (self.findExecutable(ld_name)) {
            return ld_name;
        }
        self.allocator.free(ld_name);

        if (target.os == .macos) {
            return try self.allocator.dupe(u8, "ld64");
        }

        return try self.allocator.dupe(u8, "ld");
    }

    fn getArchiverForTarget(self: *CrossCompile, target: *const TargetConfig) ![]const u8 {
        const triple = try self.getTargetTriple(target);
        defer self.allocator.free(triple);

        const ar_name = try std.fmt.allocPrint(self.allocator, "{s}-ar", .{triple});
        if (self.findExecutable(ar_name)) {
            return ar_name;
        }
        self.allocator.free(ar_name);

        return try self.allocator.dupe(u8, "ar");
    }

    fn findExecutable(self: *CrossCompile, name: []const u8) bool {
        _ = self;
        const path_env = std.process.getEnvVarOwned(std.heap.page_allocator, "PATH") catch return false;
        defer std.heap.page_allocator.free(path_env);

        var it = std.mem.tokenizeScalar(u8, path_env, ':');
        while (it.next()) |dir| {
            const full_path = std.fs.path.join(std.heap.page_allocator, &.{ dir, name }) catch continue;
            defer std.heap.page_allocator.free(full_path);

            std.fs.accessAbsolute(full_path, .{}) catch continue;
            return true;
        }
        return false;
    }

    fn addDefaultFlags(self: *CrossCompile, toolchain: *Toolchain, target: *const TargetConfig) !void {
        _ = self;

        const triple = try self.getTargetTriple(target);
        defer self.allocator.free(triple);

        try toolchain.flags.append(try std.fmt.allocPrint(self.allocator, "-target={s}", .{triple}));

        switch (target.arch) {
            .x86 => try toolchain.flags.append("-m32"),
            .x86_64 => try toolchain.flags.append("-m64"),
            .arm => {
                if (target.abi == .gnueabihf) {
                    try toolchain.flags.append("-mfloat-abi=hard");
                }
            },
            .wasm32, .wasm64 => {
                try toolchain.flags.append("-fno-exceptions");
                try toolchain.flags.append("-fno-rtti");
            },
            else => {},
        }

        switch (target.os) {
            .windows => {
                if (target.abi == .gnu) {
                    try toolchain.flags.append("-pthread");
                }
            },
            .linux, .freebsd, .openbsd, .netbsd => {
                try toolchain.flags.append("-pthread");
                try toolchain.flags.append("-fPIC");
            },
            .macos, .ios => {
                try toolchain.flags.append("-fobjc-arc");
            },
            .android => {
                try toolchain.flags.append("-fPIE");
                try toolchain.flags.append("-fPIC");
            },
            .wasi => {
                try toolchain.flags.append("-nostdlib");
                try toolchain.flags.append("-nostartfiles");
            },
            else => {},
        }

        if (target.sysroot) |sysroot| {
            try toolchain.flags.append(try std.fmt.allocPrint(self.allocator, "--sysroot={s}", .{sysroot}));
        }
    }

    pub fn getToolchain(self: *CrossCompile, target_name: []const u8) ?*Toolchain {
        if (self.targets.get(target_name)) |target| {
            const triple = self.getTargetTriple(&target) catch return null;
            defer self.allocator.free(triple);
            return self.toolchains.getPtr(triple);
        }
        return null;
    }

    pub fn getCompilerFlags(self: *CrossCompile, target_name: []const u8) ![]const []const u8 {
        if (self.getToolchain(target_name)) |toolchain| {
            return toolchain.flags.items;
        }
        return &.{};
    }

    pub fn setupEnvironment(self: *CrossCompile, target_name: []const u8) !void {
        if (self.getToolchain(target_name)) |toolchain| {
            var it = toolchain.env_vars.iterator();
            while (it.next()) |entry| {
                try std.process.setEnvironmentVariable(entry.key_ptr.*, entry.value_ptr.*);
            }

            if (toolchain.compiler.len > 0) {
                try std.process.setEnvironmentVariable("CC", toolchain.compiler);
            }
            if (toolchain.linker.len > 0) {
                try std.process.setEnvironmentVariable("LD", toolchain.linker);
            }
            if (toolchain.archiver.len > 0) {
                try std.process.setEnvironmentVariable("AR", toolchain.archiver);
            }
        }
    }

    pub fn isCrossCompiling(self: *CrossCompile, target_name: []const u8) bool {
        if (self.targets.get(target_name)) |target| {
            const native_arch = @import("builtin").cpu.arch;
            const native_os = @import("builtin").os.tag;

            const target_arch_str = @tagName(target.arch);
            const native_arch_str = @tagName(native_arch);

            const target_os_str = @tagName(target.os);
            const native_os_str = @tagName(native_os);

            return !std.mem.eql(u8, target_arch_str, native_arch_str) or
                   !std.mem.eql(u8, target_os_str, native_os_str);
        }
        return false;
    }
};