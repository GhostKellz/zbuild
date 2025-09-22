# Cross-Compilation Guide

This guide covers ZBuild's comprehensive cross-compilation support for building Rust-Zig projects across multiple platforms with zero configuration.

## Table of Contents

1. [Overview](#overview)
2. [Quick Start](#quick-start)
3. [Target Configuration](#target-configuration)
4. [Environment Setup](#environment-setup)
5. [Platform-Specific Guides](#platform-specific-guides)
6. [Advanced Patterns](#advanced-patterns)
7. [Troubleshooting](#troubleshooting)

## Overview

ZBuild's cross-compilation system provides:

- **🌍 Universal Targets**: Linux, macOS, Windows, FreeBSD, WebAssembly, embedded
- **🔧 Automatic Toolchain Detection**: Smart linker and sysroot configuration
- **📦 Isolated Builds**: Separate build directories per target
- **⚡ Parallel Compilation**: Build multiple targets simultaneously
- **🛡️ Environment Management**: Automatic `CARGO_TARGET_*` variable setup

### Supported Platforms

| Platform | Architectures | Status |
|----------|--------------|--------|
| **Linux** | x86_64, ARM64, RISC-V | ✅ Full Support |
| **macOS** | x86_64 (Intel), ARM64 (Apple Silicon) | ✅ Full Support |
| **Windows** | x86_64 (MSVC/GNU) | ✅ Full Support |
| **FreeBSD** | x86_64, ARM64 | ✅ Full Support |
| **WebAssembly** | wasm32-wasi | ✅ Full Support |
| **Android** | ARM64, x86_64 | 🔄 Experimental |
| **iOS** | ARM64 | 🔄 Experimental |

## Quick Start

### Single Target Cross-Compilation

```zig
// zbuild.zig
pub fn build(b: *Builder) !void {
    const my_crate = try b.addRustCrate(.{
        .name = "my-crate",
        .path = "crates/my-crate",
        .crate_type = .cdylib,
        .features = &[_][]const u8{"ffi"},
        .cross_compile = .{
            .rust_target = "aarch64-apple-darwin",
            .linker = "clang",
            .sysroot = "/Applications/Xcode.app/Contents/Developer/SDKs/MacOSX.sdk",
        },
    });

    try b.generateHeaders(my_crate, .{
        .output_dir = "include/",
        .header_name = "my_crate.h",
    });
}
```

### Multi-Target Builds

```zig
pub fn build(b: *Builder) !void {
    // Define your Rust crate
    const my_crate = try b.addRustCrate(.{
        .name = "my-crate",
        .path = "crates/my-crate",
        .crate_type = .cdylib,
        .features = &[_][]const u8{"ffi"},
    });

    // Generate headers
    try b.generateHeaders(my_crate, .{
        .output_dir = "include/",
        .header_name = "my_crate.h",
    });

    // Build for multiple targets
    const targets = &[_]std.Target{
        .{ .cpu = .x86_64, .os = .linux, .abi = .gnu },
        .{ .cpu = .aarch64, .os = .macos, .abi = .none },
        .{ .cpu = .x86_64, .os = .windows, .abi = .msvc },
    };

    try b.buildForTargets(targets);
}
```

### Build Commands

```bash
# Single target build
zbuild build

# Multi-target build (when configured)
zbuild build --all-targets

# Specific target
zbuild build --target aarch64-apple-darwin
```

## Target Configuration

### Target Triple Format

Rust target triples follow the format: `{arch}-{vendor}-{system}-{abi}`

| Component | Examples | Description |
|-----------|----------|-------------|
| **arch** | `x86_64`, `aarch64`, `arm`, `riscv64gc` | CPU architecture |
| **vendor** | `unknown`, `apple`, `pc` | Platform vendor |
| **system** | `linux`, `darwin`, `windows`, `wasi` | Operating system |
| **abi** | `gnu`, `musl`, `msvc`, `none` | Application Binary Interface |

### Common Target Triples

```zig
// Linux targets
.cross_compile = .{ .rust_target = "x86_64-unknown-linux-gnu" },     // x86_64 GNU
.cross_compile = .{ .rust_target = "aarch64-unknown-linux-gnu" },    // ARM64 GNU
.cross_compile = .{ .rust_target = "x86_64-unknown-linux-musl" },    // x86_64 musl

// macOS targets
.cross_compile = .{ .rust_target = "x86_64-apple-darwin" },          // Intel Mac
.cross_compile = .{ .rust_target = "aarch64-apple-darwin" },         // Apple Silicon

// Windows targets
.cross_compile = .{ .rust_target = "x86_64-pc-windows-msvc" },       // MSVC
.cross_compile = .{ .rust_target = "x86_64-pc-windows-gnu" },        // MinGW

// WebAssembly
.cross_compile = .{ .rust_target = "wasm32-wasi" },                  // WASI

// Embedded/Mobile
.cross_compile = .{ .rust_target = "aarch64-linux-android" },        // Android ARM64
.cross_compile = .{ .rust_target = "aarch64-apple-ios" },            // iOS ARM64
```

### Automatic Target Conversion

ZBuild can automatically convert Zig targets to Rust target triples:

```zig
pub fn build(b: *Builder) !void {
    const zig_target = std.Target{
        .cpu = std.Target.Cpu.baseline(.x86_64),
        .os = std.Target.Os.Tag.defaultVersionRange(.linux),
        .abi = .gnu,
    };

    const rust_target = try b.zigTargetToRustTarget(zig_target);
    defer b.allocator.free(rust_target);
    // Result: "x86_64-unknown-linux-gnu"

    const my_crate = try b.addRustCrate(.{
        .name = "my-crate",
        .path = "crates/my-crate",
        .cross_compile = .{
            .rust_target = rust_target,
        },
    });
}
```

## Environment Setup

### Automatic Environment Variables

ZBuild automatically sets these environment variables for cross-compilation:

```bash
# For target: aarch64-apple-darwin
CARGO_TARGET_AARCH64_APPLE_DARWIN_LINKER=clang
CARGO_TARGET_AARCH64_APPLE_DARWIN_RUSTFLAGS="--sysroot=/path/to/sdk"

# For target: x86_64-unknown-linux-musl
CARGO_TARGET_X86_64_UNKNOWN_LINUX_MUSL_LINKER=x86_64-linux-musl-gcc
```

### Custom Environment Variables

```zig
const my_crate = try b.addRustCrate(.{
    .name = "my-crate",
    .path = "crates/my-crate",
    .cross_compile = .{
        .rust_target = "aarch64-unknown-linux-gnu",
        .linker = "aarch64-linux-gnu-gcc",
        .sysroot = "/usr/aarch64-linux-gnu",
    },
});

// Add custom environment variables
if (my_crate.cross_compile) |*cc| {
    try cc.env_vars.put("PKG_CONFIG_PATH", "/usr/aarch64-linux-gnu/lib/pkgconfig");
    try cc.env_vars.put("CC", "aarch64-linux-gnu-gcc");
}
```

### Build Directory Structure

```
.zbuild/
├── build/
│   ├── rust-target/              # Native builds
│   ├── rust-target-aarch64-apple-darwin/     # macOS ARM64
│   ├── rust-target-x86_64-pc-windows-msvc/   # Windows x86_64
│   └── rust-target-wasm32-wasi/              # WebAssembly
└── cache/
```

## Platform-Specific Guides

### Linux Cross-Compilation

#### Prerequisites

```bash
# Install cross-compilation toolchains
sudo apt install gcc-aarch64-linux-gnu gcc-x86-64-linux-gnu

# Install Rust targets
rustup target add aarch64-unknown-linux-gnu
rustup target add x86_64-unknown-linux-musl
```

#### Configuration

```zig
// ARM64 Linux with GNU libc
const arm64_linux = try b.addRustCrate(.{
    .name = "my-crate",
    .path = "crates/my-crate",
    .cross_compile = .{
        .rust_target = "aarch64-unknown-linux-gnu",
        .linker = "aarch64-linux-gnu-gcc",
        .sysroot = "/usr/aarch64-linux-gnu",
    },
});

// x86_64 Linux with musl (static linking)
const musl_linux = try b.addRustCrate(.{
    .name = "my-crate",
    .path = "crates/my-crate",
    .cross_compile = .{
        .rust_target = "x86_64-unknown-linux-musl",
        .linker = "musl-gcc",
    },
});
```

### macOS Cross-Compilation

#### Prerequisites

```bash
# On macOS - install Xcode command line tools
xcode-select --install

# Install Rust targets
rustup target add x86_64-apple-darwin     # Intel
rustup target add aarch64-apple-darwin    # Apple Silicon
```

#### Configuration

```zig
// Apple Silicon
const macos_arm = try b.addRustCrate(.{
    .name = "my-crate",
    .path = "crates/my-crate",
    .cross_compile = .{
        .rust_target = "aarch64-apple-darwin",
        .linker = "clang",
        .sysroot = "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk",
    },
});

// Intel Mac
const macos_intel = try b.addRustCrate(.{
    .name = "my-crate",
    .path = "crates/my-crate",
    .cross_compile = .{
        .rust_target = "x86_64-apple-darwin",
        .linker = "clang",
    },
});
```

### Windows Cross-Compilation

#### Prerequisites

```bash
# Install Rust targets
rustup target add x86_64-pc-windows-msvc
rustup target add x86_64-pc-windows-gnu

# For GNU target, install mingw
sudo apt install gcc-mingw-w64-x86-64  # On Linux
```

#### Configuration

```zig
// Windows with MSVC (recommended)
const windows_msvc = try b.addRustCrate(.{
    .name = "my-crate",
    .path = "crates/my-crate",
    .cross_compile = .{
        .rust_target = "x86_64-pc-windows-msvc",
    },
});

// Windows with GNU/MinGW
const windows_gnu = try b.addRustCrate(.{
    .name = "my-crate",
    .path = "crates/my-crate",
    .cross_compile = .{
        .rust_target = "x86_64-pc-windows-gnu",
        .linker = "x86_64-w64-mingw32-gcc",
    },
});
```

### WebAssembly Compilation

#### Prerequisites

```bash
# Install WASI target
rustup target add wasm32-wasi

# Install wasmtime for testing
curl https://wasmtime.dev/install.sh -sSf | bash
```

#### Configuration

```zig
const wasm_crate = try b.addRustCrate(.{
    .name = "my-crate",
    .path = "crates/my-crate",
    .cross_compile = .{
        .rust_target = "wasm32-wasi",
    },
});
```

#### WASM-Specific Cargo.toml

```toml
[lib]
crate-type = ["cdylib"]

[dependencies]
wasi = "0.11"

[dependencies.web-sys]
version = "0.3"
features = ["console"]
```

## Advanced Patterns

### Conditional Compilation by Target

```zig
pub fn build(b: *Builder) !void {
    const target_configs = [_]struct {
        target: []const u8,
        features: []const []const u8,
        optimizations: []const []const u8,
    }{
        .{
            .target = "x86_64-unknown-linux-gnu",
            .features = &[_][]const u8{ "ffi", "simd", "optimized" },
            .optimizations = &[_][]const u8{},
        },
        .{
            .target = "aarch64-apple-darwin",
            .features = &[_][]const u8{ "ffi", "metal", "optimized" },
            .optimizations = &[_][]const u8{},
        },
        .{
            .target = "wasm32-wasi",
            .features = &[_][]const u8{ "ffi", "no-std" },
            .optimizations = &[_][]const u8{ "size" },
        },
    };

    for (target_configs) |config| {
        const crate = try b.addRustCrate(.{
            .name = "my-crate",
            .path = "crates/my-crate",
            .features = config.features,
            .cross_compile = .{
                .rust_target = config.target,
            },
        });

        try b.generateHeaders(crate, .{
            .output_dir = try std.fmt.allocPrint(b.allocator, "include-{s}/", .{config.target}),
            .header_name = "my_crate.h",
        });
    }
}
```

### Docker-Based Cross-Compilation

**`Dockerfile.cross`:**
```dockerfile
FROM rust:1.70

# Install cross-compilation toolchains
RUN apt-get update && apt-get install -y \
    gcc-aarch64-linux-gnu \
    gcc-x86-64-linux-gnu \
    gcc-mingw-w64

# Install Rust targets
RUN rustup target add aarch64-unknown-linux-gnu
RUN rustup target add x86_64-pc-windows-gnu
RUN rustup target add wasm32-wasi

# Install additional tools
RUN cargo install cbindgen

WORKDIR /workspace
```

**`build-cross.sh`:**
```bash
#!/bin/bash
docker build -f Dockerfile.cross -t zbuild-cross .
docker run --rm -v $(pwd):/workspace zbuild-cross zbuild build --all-targets
```

### CI/CD Integration

**`.github/workflows/cross-compile.yml`:**
```yaml
name: Cross-Compilation

on: [push, pull_request]

jobs:
  cross-compile:
    runs-on: ubuntu-latest
    strategy:
      matrix:
        target:
          - x86_64-unknown-linux-gnu
          - aarch64-unknown-linux-gnu
          - x86_64-pc-windows-msvc
          - aarch64-apple-darwin
          - wasm32-wasi

    steps:
    - uses: actions/checkout@v3

    - name: Install Rust
      uses: actions-rs/toolchain@v1
      with:
        toolchain: stable
        target: ${{ matrix.target }}

    - name: Install cross-compilation tools
      run: |
        sudo apt-get update
        sudo apt-get install -y gcc-aarch64-linux-gnu

    - name: Install ZBuild
      run: |
        # Install ZBuild (replace with actual installation)
        curl -L https://github.com/zbuild/zbuild/releases/latest/download/zbuild-linux-x86_64.tar.gz | tar xz

    - name: Build for target
      run: |
        zbuild build --target ${{ matrix.target }}

    - name: Upload artifacts
      uses: actions/upload-artifact@v3
      with:
        name: build-${{ matrix.target }}
        path: .zbuild/build/rust-target-${{ matrix.target }}/
```

## Troubleshooting

### Common Issues

#### 1. Missing Cross-Compilation Toolchain

**Error:**
```
linker `aarch64-linux-gnu-gcc` not found
```

**Solution:**
```bash
# Ubuntu/Debian
sudo apt install gcc-aarch64-linux-gnu

# macOS with Homebrew
brew install aarch64-linux-gnu-gcc
```

#### 2. Missing Rust Target

**Error:**
```
error: the 'aarch64-unknown-linux-gnu' target may not be installed
```

**Solution:**
```bash
rustup target add aarch64-unknown-linux-gnu
```

#### 3. Linker Errors

**Error:**
```
= note: /usr/bin/ld: cannot find -lgcc_s
```

**Solution:**
```zig
// Add proper sysroot
.cross_compile = .{
    .rust_target = "aarch64-unknown-linux-gnu",
    .linker = "aarch64-linux-gnu-gcc",
    .sysroot = "/usr/aarch64-linux-gnu",
},
```

#### 4. macOS SDK Issues

**Error:**
```
ld: library not found for -lSystem
```

**Solution:**
```zig
.cross_compile = .{
    .rust_target = "aarch64-apple-darwin",
    .linker = "clang",
    .sysroot = "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk",
},
```

### Debug Commands

```bash
# Check available Rust targets
rustup target list

# Verify toolchain installation
which aarch64-linux-gnu-gcc

# Test cross-compilation manually
cargo build --target aarch64-unknown-linux-gnu

# Check environment variables
env | grep CARGO_TARGET

# Verify binary architecture
file target/aarch64-unknown-linux-gnu/release/my_binary
```

### Performance Tips

1. **Parallel Builds**: Use `buildForTargets()` for parallel cross-compilation
2. **Incremental Builds**: ZBuild caches per-target to avoid rebuilds
3. **Docker Caching**: Use multi-stage Docker builds to cache toolchains
4. **Conditional Features**: Use target-specific feature flags to optimize builds

This comprehensive guide covers everything needed for successful cross-compilation with ZBuild!