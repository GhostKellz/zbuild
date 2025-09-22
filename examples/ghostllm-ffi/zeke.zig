const std = @import("std");
const print = std.debug.print;

// Import our zbuild Builder - this shows the new API in action
const Builder = @import("../../src/builder.zig").Builder;

// This is the zbuild.zig equivalent showing our new Rust integration API
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

    print("✅ Rust crate configured: {s}\n", .{ghostllm_core.name});
    print("✅ FFI headers will be generated in include/\n", .{});
}

// Zig code that would use the FFI (demonstration)
const c = @cImport({
    @cInclude("include/ghostllm.h");
});

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

    pub fn chatCompletion(self: *GhostLLM, allocator: std.mem.Allocator, request: ChatRequest) !ChatResponse {
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

    print("🚀 ZBuild Rust-Zig FFI Demo\n", .{});

    var ghostllm = GhostLLM.init("models/ghostllm-7b.gguf") catch |err| {
        print("❌ Failed to initialize GhostLLM: {}\n", .{err});
        return;
    };
    defer ghostllm.deinit();

    const request = ChatRequest{
        .prompt = "Explain quantum computing in simple terms",
        .max_tokens = 150,
        .temperature = 0.7,
    };

    const response = ghostllm.chatCompletion(allocator, request) catch |err| {
        print("❌ Chat completion failed: {}\n", .{err});
        return;
    };

    print("🤖 AI Response:\n{s}\n", .{response.content});
    print("📊 Tokens used: {d}\n", .{response.tokens_used});
    print("🏁 Finish reason: {s}\n", .{response.finish_reason});
}

test "ghostllm ffi integration" {
    // This would test the FFI integration
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