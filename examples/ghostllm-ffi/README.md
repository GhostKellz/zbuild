# GhostLLM FFI Example

This example demonstrates **ZBuild's Rust-Zig FFI integration** using a realistic GhostLLM AI inference engine scenario.

## Project Structure

```
ghostllm-ffi/
├── Cargo.toml           # Rust crate configuration
├── cbindgen.toml        # FFI header generation config
├── src/
│   └── lib.rs          # Rust implementation with C FFI exports
├── zeke.zig            # Zig consumer showing zbuild API usage
└── README.md           # This file
```

## Features Demonstrated

### ✅ Implemented (Phase 1 Core Features)

1. **Rust Crate Integration**
   ```zig
   const ghostllm_core = try b.addRustCrate(.{
       .name = "ghostllm-core",
       .path = ".",
       .crate_type = .cdylib,
       .features = &[_][]const u8{ "ffi", "serde_json" },
       .optimize = .ReleaseFast,
   });
   ```

2. **FFI Header Generation**
   ```zig
   try b.generateHeaders(ghostllm_core, .{
       .output_dir = "include/",
       .header_name = "ghostllm.h",
       .include_guard = "GHOSTLLM_H",
   });
   ```

3. **Automatic Cargo Integration**
   - Detects `Cargo.toml` and uses `cargo build`
   - Falls back to `rustc` for simple cases
   - Configurable features and optimization levels

4. **Type-Safe FFI Bindings**
   - JSON serialization for complex data structures
   - Memory-safe string handling
   - Proper error propagation across FFI boundary

## Build Process

### Traditional Manual Process (Before ZBuild)
```bash
# Step 1: Build Rust library manually
cd rust-crate && cargo build --release --features ffi
cp target/release/libghostllm_core.so ../

# Step 2: Generate headers manually
cbindgen --crate ghostllm-core --output ../include/ghostllm.h

# Step 3: Build Zig executable manually
cd .. && zig build-exe zeke.zig -lghostllm_core -L.

# Step 4: Cross-compile manually (nightmare!)
cargo build --release --target aarch64-apple-darwin --features ffi
cargo build --release --target x86_64-pc-windows-msvc --features ffi
# ... repeat for each platform
```

### With ZBuild (Goal)
```bash
# Single command builds everything!
zbuild build

# Cross-compile for all platforms
zbuild build --all-targets
```

## Cross-Compilation Support ✅ NEW!

ZBuild now supports seamless cross-compilation for Rust crates:

### Single Target Cross-Compilation
```zig
const ghostllm_core = try b.addRustCrate(.{
    .name = "ghostllm-core",
    .path = ".",
    .crate_type = .cdylib,
    .features = &[_][]const u8{ "ffi", "serde_json" },
    .cross_compile = .{
        .rust_target = "aarch64-apple-darwin",
        .linker = "clang",
        .sysroot = "/path/to/macos/sdk",
    },
});
```

### Multi-Target Builds
```zig
const targets = &[_]std.Target{
    .{ .cpu = .x86_64, .os = .linux, .abi = .gnu },
    .{ .cpu = .aarch64, .os = .macos, .abi = .none },
    .{ .cpu = .x86_64, .os = .windows, .abi = .msvc },
};

try b.buildForTargets(targets);
```

### Supported Platforms
- **Linux**: x86_64, ARM64, RISC-V (GNU/musl)
- **macOS**: x86_64, ARM64 (Intel/Apple Silicon)
- **Windows**: x86_64 (MSVC/GNU)
- **FreeBSD**: x86_64, ARM64
- **WebAssembly**: wasm32-wasi
- **Embedded**: Various ARM targets

## Usage Example

The Zig code demonstrates type-safe usage of the Rust FFI:

```zig
// Initialize AI engine
var ghostllm = try GhostLLM.init("models/ghostllm-7b.gguf");
defer ghostllm.deinit();

// Make AI request
const request = ChatRequest{
    .prompt = "Explain quantum computing in simple terms",
    .max_tokens = 150,
    .temperature = 0.7,
};

const response = try ghostllm.chatCompletion(allocator, request);
print("🤖 AI Response: {s}\n", .{response.content});
```

## FFI Design Patterns

### 1. **Opaque Handle Pattern**
```rust
// Rust: Export opaque pointer
#[no_mangle]
pub extern "C" fn ghostllm_init(model_path: *const c_char) -> *mut GhostLLM

// Zig: Wrap in safe interface
pub const GhostLLM = struct {
    ptr: *c.GhostLLM,
    // ... safe methods
};
```

### 2. **JSON Data Exchange**
```rust
// Rust: Accept/return JSON strings for complex data
#[no_mangle]
pub extern "C" fn ghostllm_chat_completion(
    instance: *mut GhostLLM,
    request_json: *const c_char,
) -> *mut c_char
```

### 3. **Memory Management**
```rust
// Rust: Provide cleanup functions
#[no_mangle]
pub extern "C" fn ghostllm_free_string(s: *mut c_char)

#[no_mangle]
pub extern "C" fn ghostllm_destroy(instance: *mut GhostLLM)
```

## Benefits for GhostChain + Zig L2

This pattern enables:

1. **🦀 Rust Backend**: Complex AI/blockchain logic in Rust
2. **⚡ Zig L2**: High-performance transaction processing in Zig
3. **🔗 Seamless Integration**: Type-safe FFI with zero manual configuration
4. **📦 Single Build**: One command builds the entire mixed-language project

## Next Steps

1. **Phase 2**: Smart type translation (avoid JSON overhead)
2. **Phase 3**: Async/await bridging for async Rust ↔ Zig
3. **Phase 4**: Live reload during development

This demonstrates ZBuild's vision: **Making Rust-Zig integration as easy as pure Zig development.**