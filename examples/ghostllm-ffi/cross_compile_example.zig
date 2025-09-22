const std = @import("std");
const Builder = @import("../../src/builder.zig").Builder;

// This demonstrates the multi-target cross-compilation from RUST_WISHLIST.md
pub fn build(b: *Builder) !void {
    std.debug.print("🌍 Cross-Compilation Example for GhostLLM\n", .{});

    // Define Rust library with cross-compilation support
    const ghostllm_core = try b.addRustCrate(.{
        .name = "ghostllm-core",
        .path = ".",
        .crate_type = .cdylib,
        .features = &[_][]const u8{ "ffi", "serde_json" },
        .optimize = .ReleaseFast,
        .cross_compile = .{
            .rust_target = "x86_64-unknown-linux-gnu",
            .linker = "x86_64-linux-gnu-gcc",
            .sysroot = "/usr/x86_64-linux-gnu",
        },
    });

    // Auto-generate FFI headers
    try b.generateHeaders(ghostllm_core, .{
        .output_dir = "include/",
        .header_name = "ghostllm.h",
        .include_guard = "GHOSTLLM_H",
    });

    std.debug.print("✅ Cross-compilation configured for Linux x86_64\n", .{});
}

// Multi-target build example from the wishlist
pub fn buildAllTargets(b: *Builder) !void {
    const targets = &[_]std.Target{
        std.Target{
            .cpu = std.Target.Cpu.baseline(.x86_64),
            .os = std.Target.Os.Tag.defaultVersionRange(.linux),
            .abi = .gnu,
        },
        std.Target{
            .cpu = std.Target.Cpu.baseline(.aarch64),
            .os = std.Target.Os.Tag.defaultVersionRange(.macos),
            .abi = .none,
        },
        std.Target{
            .cpu = std.Target.Cpu.baseline(.x86_64),
            .os = std.Target.Os.Tag.defaultVersionRange(.windows),
            .abi = .msvc,
        },
    };

    // Add the Rust crate
    const ghostllm_core = try b.addRustCrate(.{
        .name = "ghostllm-core",
        .path = ".",
        .crate_type = .cdylib,
        .features = &[_][]const u8{ "ffi", "serde_json" },
        .optimize = .ReleaseFast,
    });

    // Generate headers
    try b.generateHeaders(ghostllm_core, .{
        .output_dir = "include/",
        .header_name = "ghostllm.h",
        .include_guard = "GHOSTLLM_H",
    });

    // Build for all targets automatically
    try b.buildForTargets(targets);
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("🚀 ZBuild Cross-Compilation Demo\n", .{});

    // Set up builder
    var config = @import("../../src/config.zig").Config.init(allocator);
    defer config.deinit();

    var builder = try Builder.init(allocator, &config);
    defer builder.deinit();

    // Demo 1: Single target cross-compilation
    std.debug.print("\n📋 Demo 1: Single Target Cross-Compilation\n", .{});
    try build(&builder);

    // Demo 2: Multi-target builds
    std.debug.print("\n📋 Demo 2: Multi-Target Builds\n", .{});
    try buildAllTargets(&builder);

    std.debug.print("\n🎯 Cross-Compilation Benefits:\n", .{});
    std.debug.print("   • Single codebase, multiple platforms\n", .{});
    std.debug.print("   • Automatic toolchain detection\n", .{});
    std.debug.print("   • Environment variable management\n", .{});
    std.debug.print("   • Isolated build directories per target\n", .{});
    std.debug.print("   • Perfect for GhostChain deployment!\n", .{});
}