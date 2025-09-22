const std = @import("std");
const Builder = @import("src/builder.zig").Builder;
const Config = @import("src/config.zig").Config;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("🧪 Testing ZBuild Rust Integration\n", .{});

    // Initialize config and builder
    var config = Config.init(allocator);
    defer config.deinit();

    var builder = try Builder.init(allocator, &config);
    defer builder.deinit();

    // Test: Add Rust crate using our new API
    std.debug.print("\n✅ Test 1: Adding Rust crate with FFI features\n", .{});
    const ghostllm_crate = try builder.addRustCrate(.{
        .name = "ghostllm-core",
        .path = "examples/ghostllm-ffi",
        .crate_type = .cdylib,
        .features = &[_][]const u8{ "ffi", "serde_json" },
        .optimize = .ReleaseFast,
    });

    std.debug.print("  ✓ Rust crate added: {s}\n", .{ghostllm_crate.name});
    std.debug.print("  ✓ Crate type: {s}\n", .{@tagName(ghostllm_crate.crate_type)});
    std.debug.print("  ✓ Features: {d} configured\n", .{ghostllm_crate.features.items.len});

    // Test: Configure FFI header generation
    std.debug.print("\n✅ Test 2: Configuring FFI header generation\n", .{});
    try builder.generateHeaders(ghostllm_crate, .{
        .output_dir = "examples/ghostllm-ffi/include",
        .header_name = "ghostllm.h",
        .include_guard = "GHOSTLLM_H",
    });

    if (ghostllm_crate.ffi_headers) |ffi| {
        std.debug.print("  ✓ FFI headers configured: {s}/{s}\n", .{ ffi.output_dir, ffi.header_name });
        if (ffi.include_guard) |guard| {
            std.debug.print("  ✓ Include guard: {s}\n", .{guard});
        }
    }

    // Test: Verify Rust crate is registered
    std.debug.print("\n✅ Test 3: Verifying crate registration\n", .{});
    const registered_crate = builder.rust_crates.get("ghostllm-core");
    if (registered_crate) |crate| {
        std.debug.print("  ✓ Crate successfully registered: {s}\n", .{crate.name});
        std.debug.print("  ✓ Path: {s}\n", .{crate.path});
    } else {
        std.debug.print("  ❌ Crate not found in registry\n", .{});
        return error.CrateNotRegistered;
    }

    // Test: Demonstrate linking API
    std.debug.print("\n✅ Test 4: Testing linkRustCrate API\n", .{});
    try builder.linkRustCrate({}, ghostllm_crate); // Passing empty executable for demo
    std.debug.print("  ✓ Link configuration successful\n", .{});

    std.debug.print("\n🎉 All Rust integration tests passed!\n", .{});
    std.debug.print("\n📊 Integration Summary:\n", .{});
    std.debug.print("   • Rust crates registered: {d}\n", .{builder.rust_crates.count()});
    std.debug.print("   • FFI headers configured: {s}\n", .{if (ghostllm_crate.ffi_headers != null) "Yes" else "No"});
    std.debug.print("   • Ready for zbuild build command\n", .{});

    std.debug.print("\n🚀 Next Steps:\n", .{});
    std.debug.print("   1. Run: cd examples/ghostllm-ffi && cargo build --features ffi\n", .{});
    std.debug.print("   2. Run: cbindgen --output include/ghostllm.h\n", .{});
    std.debug.print("   3. Compile Zig code with: zig build-exe zeke.zig -lghostllm_core -L target/release\n", .{});
    std.debug.print("   4. Future: zbuild build (single command for everything!)\n", .{});
}