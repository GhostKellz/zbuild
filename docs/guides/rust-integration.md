# Rust Integration Guide

This comprehensive guide covers everything you need to know about integrating Rust crates into Zig projects with ZBuild, from basic FFI to advanced patterns.

## Table of Contents

1. [Overview](#overview)
2. [Setting Up Rust Crates](#setting-up-rust-crates)
3. [FFI Design Patterns](#ffi-design-patterns)
4. [Advanced Integration](#advanced-integration)
5. [Testing and Debugging](#testing-and-debugging)
6. [Performance Optimization](#performance-optimization)
7. [Real-World Examples](#real-world-examples)

## Overview

ZBuild makes Rust-Zig integration seamless by automating:

- **Cargo Integration**: Full `Cargo.toml` support with dependencies and features
- **FFI Header Generation**: Automatic C header generation via cbindgen
- **Memory Management**: Safe patterns for cross-language memory handling
- **Cross-Compilation**: Multi-platform builds with zero configuration
- **Type Safety**: Compile-time guarantees across language boundaries

## Setting Up Rust Crates

### Project Structure

```
my-project/
├── zbuild.zig              # ZBuild configuration
├── src/
│   └── main.zig            # Zig application
├── crates/
│   ├── core/               # Rust business logic
│   │   ├── Cargo.toml
│   │   └── src/lib.rs
│   └── ffi/                # FFI wrapper (optional)
│       ├── Cargo.toml
│       └── src/lib.rs
├── include/                # Generated headers
└── target/                 # Build artifacts
```

### Rust Crate Configuration

#### Basic `Cargo.toml`

```toml
[package]
name = "my-core"
version = "0.1.0"
edition = "2021"

[lib]
crate-type = ["cdylib"]  # or ["staticlib"] for static linking

[dependencies]
libc = "0.2"            # Required for FFI
serde = { version = "1.0", features = ["derive"] }
serde_json = "1.0"

[features]
default = ["ffi"]
ffi = []                # Gate FFI exports behind feature flag
optimized = []          # Performance optimizations
gpu = ["gpu-libraries"] # Optional GPU acceleration
```

#### FFI Library Structure

```rust
// src/lib.rs
use std::ffi::{CStr, CString};
use std::os::raw::{c_char, c_int};

// Business logic (pure Rust)
mod core {
    pub fn calculate(input: f64) -> f64 {
        input * 2.0 + 1.0
    }

    pub fn process_data(data: Vec<u8>) -> Result<String, String> {
        // Complex processing logic
        Ok("processed".to_string())
    }
}

// FFI exports (gated behind feature flag)
#[cfg(feature = "ffi")]
pub mod ffi {
    use super::*;

    /// Calculate a value (simple FFI)
    #[no_mangle]
    pub extern "C" fn mylib_calculate(input: f64) -> f64 {
        core::calculate(input)
    }

    /// Process data with error handling
    #[no_mangle]
    pub extern "C" fn mylib_process_data(
        data: *const u8,
        len: usize,
    ) -> *mut c_char {
        if data.is_null() {
            return std::ptr::null_mut();
        }

        let input_slice = unsafe { std::slice::from_raw_parts(data, len) };
        match core::process_data(input_slice.to_vec()) {
            Ok(result) => CString::new(result).unwrap().into_raw(),
            Err(_) => std::ptr::null_mut(),
        }
    }

    /// Free string allocated by Rust
    #[no_mangle]
    pub extern "C" fn mylib_free_string(s: *mut c_char) {
        if !s.is_null() {
            unsafe {
                let _ = CString::from_raw(s);
            }
        }
    }
}
```

### ZBuild Configuration

```zig
// zbuild.zig
const std = @import("std");
const Builder = @import("zbuild").Builder;

pub fn build(b: *Builder) !void {
    // Add Rust crate
    const my_core = try b.addRustCrate(.{
        .name = "my-core",
        .path = "crates/core",
        .crate_type = .cdylib,
        .features = &[_][]const u8{ "ffi", "optimized" },
        .optimize = .ReleaseFast,
    });

    // Generate FFI headers
    try b.generateHeaders(my_core, .{
        .output_dir = "include/",
        .header_name = "my_core.h",
        .include_guard = "MY_CORE_H",
    });
}
```

## FFI Design Patterns

### 1. Opaque Handle Pattern

For complex state management across FFI boundary:

```rust
// Rust side
pub struct MyEngine {
    config: Config,
    state: State,
}

#[no_mangle]
pub extern "C" fn engine_create(config_json: *const c_char) -> *mut MyEngine {
    let config_str = unsafe { CStr::from_ptr(config_json) }.to_str().unwrap();
    let config: Config = serde_json::from_str(config_str).unwrap();

    let engine = MyEngine::new(config);
    Box::into_raw(Box::new(engine))
}

#[no_mangle]
pub extern "C" fn engine_process(
    engine: *mut MyEngine,
    input: *const u8,
    len: usize,
) -> *mut c_char {
    let engine = unsafe { &mut *engine };
    let input_slice = unsafe { std::slice::from_raw_parts(input, len) };

    let result = engine.process(input_slice);
    CString::new(serde_json::to_string(&result).unwrap()).unwrap().into_raw()
}

#[no_mangle]
pub extern "C" fn engine_destroy(engine: *mut MyEngine) {
    if !engine.is_null() {
        unsafe {
            let _ = Box::from_raw(engine);
        }
    }
}
```

```zig
// Zig side
const MyEngine = struct {
    ptr: *c.MyEngine,

    pub fn init(allocator: std.mem.Allocator, config: Config) !MyEngine {
        const config_json = try std.json.stringifyAlloc(allocator, config, .{});
        defer allocator.free(config_json);

        const c_config = try allocator.dupeZ(u8, config_json);
        defer allocator.free(c_config);

        const ptr = c.engine_create(c_config.ptr) orelse return error.InitFailed;
        return MyEngine{ .ptr = ptr };
    }

    pub fn deinit(self: *MyEngine) void {
        c.engine_destroy(self.ptr);
    }

    pub fn process(self: *MyEngine, allocator: std.mem.Allocator, input: []const u8) ![]const u8 {
        const c_result = c.engine_process(self.ptr, input.ptr, input.len);
        if (c_result == null) return error.ProcessFailed;

        defer c.mylib_free_string(c_result);
        const result_str = std.mem.span(c_result);
        return try allocator.dupe(u8, result_str);
    }
};
```

### 2. Result Type Pattern

For robust error handling:

```rust
// Rust side
#[repr(C)]
pub struct ProcessResult {
    pub success: bool,
    pub error_code: i32,
    pub error_message: *mut c_char,
    pub data: *mut c_char,
}

#[no_mangle]
pub extern "C" fn safe_process(input: *const c_char) -> ProcessResult {
    if input.is_null() {
        return ProcessResult {
            success: false,
            error_code: 1,
            error_message: CString::new("Null input").unwrap().into_raw(),
            data: std::ptr::null_mut(),
        };
    }

    let input_str = match unsafe { CStr::from_ptr(input) }.to_str() {
        Ok(s) => s,
        Err(_) => return ProcessResult {
            success: false,
            error_code: 2,
            error_message: CString::new("Invalid UTF-8").unwrap().into_raw(),
            data: std::ptr::null_mut(),
        },
    };

    match process_internal(input_str) {
        Ok(result) => ProcessResult {
            success: true,
            error_code: 0,
            error_message: std::ptr::null_mut(),
            data: CString::new(result).unwrap().into_raw(),
        },
        Err(e) => ProcessResult {
            success: false,
            error_code: 3,
            error_message: CString::new(e.to_string()).unwrap().into_raw(),
            data: std::ptr::null_mut(),
        },
    }
}
```

```zig
// Zig side
pub fn safeProcess(allocator: std.mem.Allocator, input: []const u8) ![]const u8 {
    const c_input = try allocator.dupeZ(u8, input);
    defer allocator.free(c_input);

    const result = c.safe_process(c_input.ptr);
    defer {
        if (result.error_message != null) c.mylib_free_string(result.error_message);
        if (result.data != null) c.mylib_free_string(result.data);
    }

    if (!result.success) {
        const error_msg = if (result.error_message != null)
            std.mem.span(result.error_message)
        else
            "Unknown error";
        std.debug.print("Error {d}: {s}\n", .{ result.error_code, error_msg });
        return error.ProcessingFailed;
    }

    if (result.data == null) return error.NoData;
    const data_str = std.mem.span(result.data);
    return try allocator.dupe(u8, data_str);
}
```

### 3. Callback Pattern

For asynchronous operations:

```rust
// Rust side
pub type ProgressCallback = extern "C" fn(progress: f32, user_data: *mut c_void);

#[no_mangle]
pub extern "C" fn long_operation(
    callback: Option<ProgressCallback>,
    user_data: *mut c_void,
) -> bool {
    for i in 0..100 {
        // Do work
        std::thread::sleep(std::time::Duration::from_millis(10));

        // Report progress
        if let Some(cb) = callback {
            cb(i as f32 / 100.0, user_data);
        }
    }
    true
}
```

```zig
// Zig side
const ProgressContext = struct {
    total_steps: usize,
    current_step: usize,
};

export fn progressCallback(progress: f32, user_data: ?*anyopaque) void {
    if (user_data) |data| {
        const ctx: *ProgressContext = @ptrCast(@alignCast(data));
        std.debug.print("Progress: {d:.1}%\n", .{progress * 100});
    }
}

pub fn runLongOperation() !void {
    var ctx = ProgressContext{ .total_steps = 100, .current_step = 0 };
    const success = c.long_operation(progressCallback, &ctx);
    if (!success) return error.OperationFailed;
}
```

## Advanced Integration

### Async Rust with Sync Zig

```rust
// Rust side - async runtime wrapper
use tokio::runtime::Runtime;

static mut RUNTIME: Option<Runtime> = None;

#[no_mangle]
pub extern "C" fn async_runtime_init() -> bool {
    match Runtime::new() {
        Ok(rt) => {
            unsafe { RUNTIME = Some(rt); }
            true
        }
        Err(_) => false,
    }
}

#[no_mangle]
pub extern "C" fn async_fetch_data(url: *const c_char) -> *mut c_char {
    let url_str = unsafe { CStr::from_ptr(url) }.to_str().unwrap();

    unsafe {
        if let Some(rt) = &RUNTIME {
            match rt.block_on(fetch_data_async(url_str)) {
                Ok(data) => CString::new(data).unwrap().into_raw(),
                Err(_) => std::ptr::null_mut(),
            }
        } else {
            std::ptr::null_mut()
        }
    }
}

async fn fetch_data_async(url: &str) -> Result<String, Box<dyn std::error::Error>> {
    // Async HTTP request
    Ok("data".to_string())
}
```

### GPU Acceleration Integration

```rust
// Rust side with CUDA/OpenCL
#[cfg(feature = "gpu")]
#[no_mangle]
pub extern "C" fn gpu_process_array(
    data: *const f32,
    len: usize,
    output: *mut f32,
) -> bool {
    let input_slice = unsafe { std::slice::from_raw_parts(data, len) };
    let output_slice = unsafe { std::slice::from_raw_parts_mut(output, len) };

    match gpu_kernel_launch(input_slice, output_slice) {
        Ok(_) => true,
        Err(_) => false,
    }
}

#[cfg(feature = "gpu")]
fn gpu_kernel_launch(input: &[f32], output: &mut [f32]) -> Result<(), GpuError> {
    // GPU processing implementation
    Ok(())
}
```

## Testing and Debugging

### Unit Testing Rust FFI

```rust
#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_ffi_calculate() {
        let result = ffi::mylib_calculate(5.0);
        assert_eq!(result, 11.0);
    }

    #[test]
    fn test_ffi_string_handling() {
        let input = CString::new("test").unwrap();
        let result = ffi::mylib_process_data(input.as_ptr().cast(), 4);

        assert!(!result.is_null());

        let result_str = unsafe { CStr::from_ptr(result) };
        assert_eq!(result_str.to_str().unwrap(), "processed");

        ffi::mylib_free_string(result);
    }
}
```

### Integration Testing

```zig
// test/integration_test.zig
const std = @import("std");
const testing = std.testing;

const c = @cImport({
    @cInclude("include/my_core.h");
});

test "rust-zig integration" {
    const result = c.mylib_calculate(10.0);
    try testing.expect(result == 21.0);
}

test "memory management" {
    const input = "test data";
    const c_input = try testing.allocator.dupeZ(u8, input);
    defer testing.allocator.free(c_input);

    const result = c.mylib_process_data(c_input.ptr, input.len);
    defer c.mylib_free_string(result);

    try testing.expect(result != null);
    const result_str = std.mem.span(result);
    try testing.expectEqualStrings("processed", result_str);
}
```

### Debugging Tips

1. **Use AddressSanitizer** for memory issues:
   ```bash
   RUSTFLAGS="-Z sanitizer=address" cargo build --target x86_64-unknown-linux-gnu
   ```

2. **Enable debug symbols**:
   ```toml
   [profile.release]
   debug = true
   ```

3. **Valgrind integration**:
   ```bash
   valgrind --tool=memcheck --leak-check=full ./my_app
   ```

## Performance Optimization

### 1. Zero-Copy Data Exchange

```rust
// Rust side - use slices instead of copying
#[no_mangle]
pub extern "C" fn process_slice(
    data: *const f64,
    len: usize,
    output: *mut f64,
) -> bool {
    let input = unsafe { std::slice::from_raw_parts(data, len) };
    let output_slice = unsafe { std::slice::from_raw_parts_mut(output, len) };

    // Process in-place, no allocation
    for (input_val, output_val) in input.iter().zip(output_slice.iter_mut()) {
        *output_val = input_val * 2.0;
    }
    true
}
```

### 2. Bulk Operations

```rust
// Process multiple items at once
#[no_mangle]
pub extern "C" fn batch_process(
    items: *const *const c_char,
    count: usize,
    results: *mut *mut c_char,
) -> usize {
    let input_ptrs = unsafe { std::slice::from_raw_parts(items, count) };
    let output_ptrs = unsafe { std::slice::from_raw_parts_mut(results, count) };

    let mut processed = 0;
    for (i, &input_ptr) in input_ptrs.iter().enumerate() {
        if let Ok(input_str) = unsafe { CStr::from_ptr(input_ptr) }.to_str() {
            if let Ok(result) = process_item(input_str) {
                output_ptrs[i] = CString::new(result).unwrap().into_raw();
                processed += 1;
            }
        }
    }
    processed
}
```

### 3. Memory Pool Pattern

```rust
// Pre-allocate memory pools for frequent allocations
use std::sync::Mutex;

static MEMORY_POOL: Mutex<Vec<Vec<u8>>> = Mutex::new(Vec::new());

#[no_mangle]
pub extern "C" fn get_buffer(size: usize) -> *mut u8 {
    let mut pool = MEMORY_POOL.lock().unwrap();

    if let Some(mut buffer) = pool.pop() {
        if buffer.capacity() >= size {
            buffer.clear();
            buffer.resize(size, 0);
            let ptr = buffer.as_mut_ptr();
            std::mem::forget(buffer);
            return ptr;
        }
    }

    let mut buffer = Vec::with_capacity(size);
    buffer.resize(size, 0);
    let ptr = buffer.as_mut_ptr();
    std::mem::forget(buffer);
    ptr
}

#[no_mangle]
pub extern "C" fn return_buffer(ptr: *mut u8, size: usize) {
    let buffer = unsafe { Vec::from_raw_parts(ptr, size, size) };
    let mut pool = MEMORY_POOL.lock().unwrap();
    pool.push(buffer);
}
```

## Real-World Examples

### AI/ML Pipeline

```rust
// Rust AI inference engine
pub struct InferenceEngine {
    model: Model,
    tokenizer: Tokenizer,
}

#[no_mangle]
pub extern "C" fn ai_engine_create(model_path: *const c_char) -> *mut InferenceEngine {
    // Load ML model
}

#[no_mangle]
pub extern "C" fn ai_generate_text(
    engine: *mut InferenceEngine,
    prompt: *const c_char,
    max_tokens: usize,
) -> *mut c_char {
    // Generate AI response
}
```

### Blockchain Integration

```rust
// Rust blockchain consensus layer
#[no_mangle]
pub extern "C" fn blockchain_validate_block(
    block_data: *const u8,
    block_len: usize,
) -> ValidationResult {
    // Validate blockchain block
}

#[no_mangle]
pub extern "C" fn blockchain_mine_block(
    transactions: *const *const u8,
    tx_count: usize,
    difficulty: u32,
) -> *mut c_char {
    // Mine new block
}
```

This guide provides the foundation for building robust, high-performance Rust-Zig integrations with ZBuild!