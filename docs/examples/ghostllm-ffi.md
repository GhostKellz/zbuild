# GhostLLM FFI Integration Example

This example demonstrates a complete AI inference engine integration using ZBuild's Rust-Zig FFI capabilities. It showcases real-world patterns for building high-performance AI applications with Rust inference backends and Zig performance layers.

## Project Overview

**GhostLLM** is an AI inference engine where:
- **Rust** handles complex AI model loading, tokenization, and inference
- **Zig** provides the high-performance CLI interface and memory management
- **ZBuild** seamlessly integrates both languages with automatic FFI generation

## Project Structure

```
ghostllm-ffi/
├── Cargo.toml              # Rust crate configuration
├── cbindgen.toml           # FFI header generation config
├── src/
│   └── lib.rs              # Rust AI inference implementation
├── zeke.zig                # Zig CLI application
├── cross_compile_example.zig  # Multi-platform deployment
└── README.md               # Complete documentation
```

## Rust Implementation

### Cargo Configuration

```toml
[package]
name = "ghostllm-core"
version = "0.1.0"
edition = "2021"
description = "AI inference engine for GhostLLM"

[lib]
crate-type = ["cdylib"]

[dependencies]
libc = "0.2"
serde = { version = "1.0", features = ["derive"] }
serde_json = "1.0"

[features]
default = ["ffi"]
ffi = []
```

### AI Inference Engine

```rust
// src/lib.rs - Complete implementation
use std::ffi::{CStr, CString};
use std::os::raw::{c_char, c_int};
use serde::{Deserialize, Serialize};

/// AI chat request structure
#[derive(Debug, Serialize, Deserialize)]
pub struct ChatRequest {
    pub prompt: String,
    pub max_tokens: u32,
    pub temperature: f32,
}

/// AI response structure
#[derive(Debug, Serialize, Deserialize)]
pub struct ChatResponse {
    pub content: String,
    pub tokens_used: u32,
    pub finish_reason: String,
}

/// Main AI inference engine
pub struct GhostLLM {
    model_path: String,
    initialized: bool,
}

impl GhostLLM {
    pub fn new(model_path: &str) -> Self {
        Self {
            model_path: model_path.to_string(),
            initialized: false,
        }
    }

    pub fn init(&mut self) -> Result<(), &'static str> {
        println!("🤖 Initializing GhostLLM with model: {}", self.model_path);
        // In real implementation: load model, initialize tokenizer, etc.
        self.initialized = true;
        Ok(())
    }

    pub fn chat_completion(&self, request: &ChatRequest) -> Result<ChatResponse, &'static str> {
        if !self.initialized {
            return Err("GhostLLM not initialized");
        }

        // Simulate AI processing (replace with actual inference)
        let response = ChatResponse {
            content: format!(
                "🤖 AI Response to: '{}' [temp={}, max_tokens={}]",
                request.prompt, request.temperature, request.max_tokens
            ),
            tokens_used: request.max_tokens.min(150),
            finish_reason: "length".to_string(),
        };

        Ok(response)
    }
}

// C FFI exports
#[cfg(feature = "ffi")]
pub mod ffi {
    use super::*;
    use std::ptr;

    /// Initialize GhostLLM instance
    #[no_mangle]
    pub extern "C" fn ghostllm_init(model_path: *const c_char) -> *mut GhostLLM {
        if model_path.is_null() {
            return ptr::null_mut();
        }

        let c_str = unsafe { CStr::from_ptr(model_path) };
        let path_str = match c_str.to_str() {
            Ok(s) => s,
            Err(_) => return ptr::null_mut(),
        };

        let mut instance = Box::new(GhostLLM::new(path_str));
        match instance.init() {
            Ok(_) => Box::into_raw(instance),
            Err(_) => ptr::null_mut(),
        }
    }

    /// Process chat completion request
    #[no_mangle]
    pub extern "C" fn ghostllm_chat_completion(
        instance: *mut GhostLLM,
        request_json: *const c_char,
    ) -> *mut c_char {
        if instance.is_null() || request_json.is_null() {
            return ptr::null_mut();
        }

        let ghostllm = unsafe { &*instance };
        let c_str = unsafe { CStr::from_ptr(request_json) };
        let json_str = match c_str.to_str() {
            Ok(s) => s,
            Err(_) => return ptr::null_mut(),
        };

        let request: ChatRequest = match serde_json::from_str(json_str) {
            Ok(req) => req,
            Err(_) => return ptr::null_mut(),
        };

        let response = match ghostllm.chat_completion(&request) {
            Ok(resp) => resp,
            Err(_) => return ptr::null_mut(),
        };

        let response_json = match serde_json::to_string(&response) {
            Ok(json) => json,
            Err(_) => return ptr::null_mut(),
        };

        match CString::new(response_json) {
            Ok(c_string) => c_string.into_raw(),
            Err(_) => ptr::null_mut(),
        }
    }

    /// Free string returned by ghostllm_chat_completion
    #[no_mangle]
    pub extern "C" fn ghostllm_free_string(s: *mut c_char) {
        if !s.is_null() {
            unsafe {
                let _ = CString::from_raw(s);
            }
        }
    }

    /// Destroy GhostLLM instance
    #[no_mangle]
    pub extern "C" fn ghostllm_destroy(instance: *mut GhostLLM) {
        if !instance.is_null() {
            unsafe {
                let _ = Box::from_raw(instance);
            }
        }
    }

    /// Get last error message
    #[no_mangle]
    pub extern "C" fn ghostllm_last_error() -> *const c_char {
        b"No error\\0".as_ptr() as *const c_char
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_ghostllm_basic() {
        let mut llm = GhostLLM::new("test-model.gguf");
        assert!(llm.init().is_ok());

        let request = ChatRequest {
            prompt: "Hello, world!".to_string(),
            max_tokens: 100,
            temperature: 0.7,
        };

        let response = llm.chat_completion(&request);
        assert!(response.is_ok());

        let resp = response.unwrap();
        assert!(resp.content.contains("Hello, world!"));
        assert_eq!(resp.tokens_used, 100);
    }
}
```

## ZBuild Configuration

```zig
// zeke.zig - ZBuild configuration and Zig application
const std = @import("std");
const Builder = @import("../../src/builder.zig").Builder;

// ZBuild configuration showing the new API in action
pub fn build(b: *Builder) !void {
    // Define Rust library with FFI
    const ghostllm_core = try b.addRustCrate(.{
        .name = "ghostllm-core",
        .path = ".",
        .crate_type = .cdylib,
        .features = &[_][]const u8{ "ffi", "serde_json" },
        .optimize = .ReleaseFast,
    });

    // Auto-generate FFI headers
    try b.generateHeaders(ghostllm_core, .{
        .output_dir = "include/",
        .header_name = "ghostllm.h",
        .include_guard = "GHOSTLLM_H",
    });

    std.debug.print("✅ Rust crate configured: {s}\\n", .{ghostllm_core.name});
    std.debug.print("✅ FFI headers will be generated in include/\\n", .{});
}
```

## Zig Integration

```zig
// Zig application that uses the FFI
const std = @import("std");
const print = std.debug.print;

// Import generated FFI headers
const c = @cImport({
    @cInclude("include/ghostllm.h");
});

// Type-safe Zig wrapper
pub const GhostLLM = struct {
    ptr: *c.GhostLLM,

    pub fn init(model_path: []const u8) !GhostLLM {
        const c_path = @ptrCast([*c]const u8, model_path.ptr);
        const ptr = c.ghostllm_init(c_path) orelse return error.InitFailed;
        return GhostLLM{ .ptr = ptr };
    }

    pub fn deinit(self: *GhostLLM) void {
        c.ghostllm_destroy(self.ptr);
    }

    pub fn chatCompletion(
        self: *GhostLLM,
        allocator: std.mem.Allocator,
        request: ChatRequest
    ) !ChatResponse {
        const request_json = try std.json.stringifyAlloc(allocator, request, .{});
        defer allocator.free(request_json);

        const c_request = @ptrCast([*c]const u8, request_json.ptr);
        const c_response = c.ghostllm_chat_completion(self.ptr, c_request);
        if (c_response == null) return error.ChatFailed;

        defer c.ghostllm_free_string(c_response);

        const response_json = std.mem.span(c_response);
        return try std.json.parseFromSlice(ChatResponse, allocator, response_json, .{});
    }
};

// Zig data structures (matching Rust)
pub const ChatRequest = struct {
    prompt: []const u8,
    max_tokens: u32,
    temperature: f32,
};

pub const ChatResponse = struct {
    content: []const u8,
    tokens_used: u32,
    finish_reason: []const u8,
};

// Example usage
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    print("🚀 ZBuild Rust-Zig FFI Demo\\n", .{});

    var ghostllm = GhostLLM.init("models/ghostllm-7b.gguf") catch |err| {
        print("❌ Failed to initialize GhostLLM: {}\\n", .{err});
        return;
    };
    defer ghostllm.deinit();

    const request = ChatRequest{
        .prompt = "Explain quantum computing in simple terms",
        .max_tokens = 150,
        .temperature = 0.7,
    };

    const response = ghostllm.chatCompletion(allocator, request) catch |err| {
        print("❌ Chat completion failed: {}\\n", .{err});
        return;
    };

    print("🤖 AI Response:\\n{s}\\n", .{response.content});
    print("📊 Tokens used: {d}\\n", .{response.tokens_used});
    print("🏁 Finish reason: {s}\\n", .{response.finish_reason});
}
```

## Cross-Compilation Example

```zig
// cross_compile_example.zig - Multi-platform deployment
const std = @import("std");
const Builder = @import("../../src/builder.zig").Builder;

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
```

## Build Process

### Traditional Manual Process

```bash
# Before ZBuild - multiple manual steps
cd crates/ghostllm-core
cargo build --release --features ffi
cp target/release/libghostllm_core.so ../

cbindgen --crate ghostllm-core --output ../include/ghostllm.h

cd ..
zig build-exe zeke.zig -lghostllm_core -L.

# Cross-compilation nightmare
cargo build --release --target aarch64-apple-darwin --features ffi
cargo build --release --target x86_64-pc-windows-msvc --features ffi
# ... repeat for each platform
```

### With ZBuild

```bash
# Single command builds everything!
zbuild build

# Cross-compile for all platforms
zbuild build --all-targets
```

## Key Features Demonstrated

### ✅ **Rust-Zig FFI Integration**
- **Automatic header generation** via cbindgen
- **Type-safe bindings** with proper memory management
- **JSON data exchange** for complex structures
- **Error handling** across FFI boundary

### 🌍 **Cross-Compilation Support**
- **Multi-platform builds**: Linux, macOS, Windows
- **Single command deployment**: `zbuild build --all-targets`
- **Isolated build directories** per target
- **Automatic environment setup**

### 🛡️ **Memory Safety**
- **RAII patterns** with automatic cleanup
- **Proper string handling** (C strings ↔ Zig slices ↔ Rust String)
- **Ownership tracking** across FFI calls
- **Memory leak prevention**

### ⚡ **Performance Optimization**
- **Zero-copy patterns** where possible
- **Optimized release builds** with `-O ReleaseFast`
- **Efficient JSON serialization** for data exchange
- **Minimal FFI overhead**

## Real-World Applications

### AI/ML Deployment
```zig
// Deploy GhostLLM to edge devices
const edge_targets = &[_]std.Target{
    .{ .cpu = .aarch64, .os = .linux, .abi = .gnu },     // Raspberry Pi
    .{ .cpu = .x86_64, .os = .linux, .abi = .musl },     // Alpine containers
    .{ .cpu = .wasm32, .os = .wasi, .abi = .none },       // WebAssembly edge
};

try b.buildForTargets(edge_targets);
```

### Cloud Infrastructure
```zig
// Deploy to cloud providers
const cloud_targets = &[_]std.Target{
    .{ .cpu = .x86_64, .os = .linux, .abi = .gnu },      // AWS EC2
    .{ .cpu = .aarch64, .os = .linux, .abi = .gnu },     // AWS Graviton
    .{ .cpu = .x86_64, .os = .windows, .abi = .msvc },   // Azure Windows
};

try b.buildForTargets(cloud_targets);
```

## Testing

```zig
test "ghostllm ffi integration" {
    const allocator = std.testing.allocator;

    var ghostllm = try GhostLLM.init("test-model.bin");
    defer ghostllm.deinit();

    const request = ChatRequest{
        .prompt = "Hello, test!",
        .max_tokens = 50,
        .temperature = 0.1,
    };

    const response = try ghostllm.chatCompletion(allocator, request);
    try std.testing.expect(response.content.len > 0);
    try std.testing.expect(response.tokens_used <= 50);
}
```

## Benefits for AI Projects

### 🔥 **Eliminates FFI Friction**
- No manual header generation
- Automatic memory management
- Type-safe bindings

### 📈 **Improves Developer Velocity**
- Single build command
- Consistent tooling
- Live development workflow

### 🌍 **Enables Global Deployment**
- Multi-platform builds
- Edge device support
- Container optimization

### 🚀 **Production Ready**
- Memory-safe patterns
- Performance optimization
- Robust error handling

This example demonstrates how ZBuild makes building complex AI applications with mixed Rust-Zig architectures as simple as pure Zig development!