# ZBuild Quick Start Guide

Get up and running with ZBuild in 5 minutes! This guide will walk you through creating your first mixed Rust-Zig project with FFI integration.

## 🚀 Prerequisites

- **Zig 0.16+**: [Install Zig](https://ziglang.org/download/)
- **Rust 1.70+**: [Install Rust](https://rustup.rs/)
- **cbindgen**: `cargo install cbindgen`

## 📦 Installation

### Option 1: Build from Source
```bash
git clone https://github.com/zbuild/zbuild
cd zbuild
zig build
export PATH=$PWD/zig-out/bin:$PATH
```

### Option 2: Download Binary (Coming Soon)
```bash
# Will be available soon
curl -L https://github.com/zbuild/zbuild/releases/latest/download/zbuild-linux-x86_64.tar.gz | tar xz
```

## 🏗️ Create Your First Project

### 1. Initialize Project Structure
```bash
mkdir my-rust-zig-project
cd my-rust-zig-project

# Create Rust crate
cargo init --lib crates/calculator --name calculator
cd crates/calculator
```

### 2. Set Up Rust FFI Crate

**`crates/calculator/Cargo.toml`:**
```toml
[package]
name = "calculator"
version = "0.1.0"
edition = "2021"

[lib]
crate-type = ["cdylib"]

[dependencies]
libc = "0.2"

[features]
default = ["ffi"]
ffi = []
```

**`crates/calculator/src/lib.rs`:**
```rust
use std::os::raw::c_int;

/// Add two numbers
#[no_mangle]
pub extern "C" fn calculator_add(a: c_int, b: c_int) -> c_int {
    a + b
}

/// Multiply two numbers
#[no_mangle]
pub extern "C" fn calculator_multiply(a: c_int, b: c_int) -> c_int {
    a * b
}

/// Get calculator version
#[no_mangle]
pub extern "C" fn calculator_version() -> c_int {
    100 // Version 1.0.0
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_add() {
        assert_eq!(calculator_add(2, 3), 5);
    }

    #[test]
    fn test_multiply() {
        assert_eq!(calculator_multiply(4, 5), 20);
    }
}
```

**`crates/calculator/cbindgen.toml`:**
```toml
language = "C"
header = "/* Calculator FFI */\n"
include_guard = "CALCULATOR_H"
cpp_compat = true
```

### 3. Create ZBuild Configuration

**`zbuild.zig` (in project root):**
```zig
const std = @import("std");
const Builder = @import("zbuild").Builder;

pub fn build(b: *Builder) !void {
    // Add Rust calculator crate
    const calculator = try b.addRustCrate(.{
        .name = "calculator",
        .path = "crates/calculator",
        .crate_type = .cdylib,
        .features = &[_][]const u8{"ffi"},
        .optimize = .ReleaseFast,
    });

    // Generate FFI headers
    try b.generateHeaders(calculator, .{
        .output_dir = "include/",
        .header_name = "calculator.h",
        .include_guard = "CALCULATOR_H",
    });

    std.debug.print("✅ Calculator crate configured!\n", .{});
}
```

### 4. Create Zig Application

**`src/main.zig`:**
```zig
const std = @import("std");
const print = std.debug.print;

// Import generated FFI headers
const c = @cImport({
    @cInclude("include/calculator.h");
});

pub fn main() !void {
    print("🧮 ZBuild Calculator Demo\n", .{});

    // Use Rust functions from Zig
    const a: i32 = 10;
    const b: i32 = 5;

    const sum = c.calculator_add(a, b);
    const product = c.calculator_multiply(a, b);
    const version = c.calculator_version();

    print("Calculator version: {d}\n", .{version});
    print("{d} + {d} = {d}\n", .{ a, b, sum });
    print("{d} × {d} = {d}\n", .{ a, b, product });
    print("✅ Rust-Zig FFI working perfectly!\n", .{});
}
```

### 5. Build and Run

```bash
# Build everything with ZBuild
zbuild build

# You should see:
# Building Rust crates...
#   Building Rust crate: calculator
# Generated FFI headers: include/calculator.h
#   ✅ Rust crate built: calculator
# ✅ Calculator crate configured!
```

**Manual build (until ZBuild CLI is complete):**
```bash
# Build Rust crate
cd crates/calculator
cargo build --release --features ffi

# Generate headers
cbindgen --output ../../include/calculator.h

# Build Zig executable
cd ../..
zig build-exe src/main.zig -I include -L crates/calculator/target/release -lcalculator

# Run it!
./main
```

**Expected Output:**
```
🧮 ZBuild Calculator Demo
Calculator version: 100
10 + 5 = 15
10 × 5 = 50
✅ Rust-Zig FFI working perfectly!
```

## 🌍 Cross-Compilation Example

Add cross-compilation to your `zbuild.zig`:

```zig
pub fn build(b: *Builder) !void {
    const calculator = try b.addRustCrate(.{
        .name = "calculator",
        .path = "crates/calculator",
        .crate_type = .cdylib,
        .features = &[_][]const u8{"ffi"},
        .optimize = .ReleaseFast,
        .cross_compile = .{
            .rust_target = "aarch64-apple-darwin",
            .linker = "clang",
        },
    });

    try b.generateHeaders(calculator, .{
        .output_dir = "include/",
        .header_name = "calculator.h",
    });

    // Multi-target build
    const targets = &[_]std.Target{
        .{ .cpu = .x86_64, .os = .linux, .abi = .gnu },
        .{ .cpu = .aarch64, .os = .macos, .abi = .none },
        .{ .cpu = .x86_64, .os = .windows, .abi = .msvc },
    };

    try b.buildForTargets(targets);
}
```

## 🎯 What You Just Built

✅ **Rust FFI Crate**: High-performance calculation functions
✅ **Automatic Header Generation**: Type-safe C headers via cbindgen
✅ **Zig Integration**: Seamless FFI calls from Zig
✅ **Cross-Compilation Ready**: Multi-platform builds
✅ **Zero Configuration**: Works out of the box

## 🚀 Next Steps

1. **[Rust Integration Guide](rust-integration.md)** - Deep dive into advanced FFI patterns
2. **[Cross-Compilation Guide](cross-compilation.md)** - Multi-platform deployment
3. **[API Reference](../api/rust-integration.md)** - Complete API documentation
4. **[Examples](../examples/)** - More complex real-world examples

## 🎉 You're Ready!

You've successfully created a mixed Rust-Zig project with ZBuild! The same patterns work for:

- **AI/ML Projects**: Rust inference engines + Zig performance layers
- **Blockchain**: Rust consensus + Zig high-throughput processing
- **System Tools**: Rust logic + Zig low-level optimization
- **Game Engines**: Rust gameplay + Zig performance-critical code

**Welcome to the future of mixed-language development!** 🦀⚡