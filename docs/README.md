# ZBuild Documentation

**Modern Build System with First-Class Rust Integration**

ZBuild is a powerful build system that makes Rust-Zig FFI integration as easy as pure Zig development, with advanced cross-compilation support for global deployment.

## 📚 Documentation Structure

### 🚀 **Getting Started**
- [**Quick Start Guide**](guides/quick-start.md) - Get up and running in 5 minutes
- [**Installation**](guides/installation.md) - Setup ZBuild on your system
- [**First Project**](guides/first-project.md) - Build your first mixed Rust-Zig project

### 📖 **Guides**
- [**Rust Integration Guide**](guides/rust-integration.md) - Complete Rust-Zig FFI workflow
- [**Cross-Compilation Guide**](guides/cross-compilation.md) - Multi-platform builds
- [**FFI Best Practices**](guides/ffi-best-practices.md) - Type-safe FFI patterns
- [**Performance Optimization**](guides/performance.md) - Build performance tuning

### 🔧 **API Reference**
- [**Builder API**](api/builder.md) - Core build system API
- [**Rust Integration API**](api/rust-integration.md) - `addRustCrate()` and related functions
- [**Cross-Compilation API**](api/cross-compilation.md) - Multi-target build APIs
- [**Configuration**](api/configuration.md) - `zbuild.json` and project configuration

### 💡 **Examples**
- [**GhostLLM FFI Example**](examples/ghostllm-ffi.md) - Complete AI inference integration
- [**Cross-Compilation Examples**](examples/cross-compilation.md) - Multi-platform deployment
- [**Advanced Patterns**](examples/advanced-patterns.md) - Complex project structures

### 📘 **Reference**
- [**Cargo Integration**](reference/cargo.md) - How ZBuild works with Cargo
- [**Target Mapping**](reference/target-mapping.md) - Zig ↔ Rust target conversion
- [**Environment Variables**](reference/environment.md) - Build environment configuration
- [**Troubleshooting**](reference/troubleshooting.md) - Common issues and solutions

## 🎯 **Key Features**

### ✅ **Rust Integration**
- **Seamless FFI**: Automatic header generation and linking
- **Cargo Integration**: Full `Cargo.toml` support with feature flags
- **Type Safety**: Memory-safe bindings with proper cleanup

### 🌍 **Cross-Compilation**
- **Multi-Target Builds**: Single command for all platforms
- **Smart Environment Setup**: Automatic toolchain configuration
- **Global Deployment**: Linux, macOS, Windows, WebAssembly, and more

### ⚡ **Performance**
- **Incremental Builds**: Only rebuild what changed
- **Parallel Compilation**: Multi-core build acceleration
- **Intelligent Caching**: Fast subsequent builds

### 🛠️ **Developer Experience**
- **Zero Configuration**: Works out of the box
- **Rich Diagnostics**: Clear error messages and build feedback
- **IDE Integration**: VSCode, Vim, and other editor support

## 🚀 **Quick Example**

```zig
// zbuild.zig - Define your mixed Rust-Zig project
const Builder = @import("zbuild").Builder;

pub fn build(b: *Builder) !void {
    // Add Rust crate with FFI
    const ai_engine = try b.addRustCrate(.{
        .name = "ai-engine",
        .path = "crates/ai-engine",
        .crate_type = .cdylib,
        .features = &[_][]const u8{ "ffi", "optimized" },
        .optimize = .ReleaseFast,
    });

    // Generate FFI headers automatically
    try b.generateHeaders(ai_engine, .{
        .output_dir = "include/",
        .header_name = "ai_engine.h",
        .include_guard = "AI_ENGINE_H",
    });

    // Cross-compile for deployment
    const targets = &[_]std.Target{
        .{ .cpu = .x86_64, .os = .linux, .abi = .gnu },
        .{ .cpu = .aarch64, .os = .macos, .abi = .none },
        .{ .cpu = .x86_64, .os = .windows, .abi = .msvc },
    };

    try b.buildForTargets(targets);
}
```

```bash
# Build everything with one command
zbuild build
```

## 🌟 **Perfect For**

### 🦀 **Rust + Zig Projects**
- **AI/ML Applications**: Rust inference engines + Zig performance layers
- **Blockchain Infrastructure**: Rust consensus + Zig high-throughput layers
- **System Tools**: Rust logic + Zig low-level optimization
- **Game Engines**: Rust game logic + Zig performance-critical code

### 🌍 **Global Deployment**
- **Cloud Infrastructure**: Multi-platform server deployment
- **Edge Computing**: ARM, x86, WebAssembly targets
- **Mobile/Embedded**: Cross-compile for any device
- **CI/CD Pipelines**: Consistent builds across all platforms

## 🛣️ **Roadmap**

### ✅ **Phase 1: Core Integration (Complete)**
- Rust crate compilation and linking
- FFI header generation
- Basic cross-compilation support
- Cargo integration

### 🔄 **Phase 2: Advanced Features (In Progress)**
- Smart type translation (reduce JSON overhead)
- Async/await bridging between Rust and Zig
- Advanced memory management patterns
- Performance profiling integration

### 💡 **Phase 3: Developer Experience**
- Live reload for mixed projects
- IDE integration and tooling
- Unified testing framework
- Visual dependency graphs

### 🚀 **Phase 4: Enterprise Features**
- Security auditing and SBOM generation
- Compliance reporting
- Multi-format packaging
- Enterprise deployment tools

## 🤝 **Contributing**

ZBuild is open source and welcomes contributions! See our [Contributing Guide](../CONTRIBUTING.md) for details.

## 📞 **Support**

- **Issues**: [GitHub Issues](https://github.com/zbuild/zbuild/issues)
- **Discussions**: [GitHub Discussions](https://github.com/zbuild/zbuild/discussions)
- **Documentation**: This docs directory
- **Examples**: `examples/` directory in the repository

---

**Ready to build the future with Rust + Zig? Start with our [Quick Start Guide](guides/quick-start.md)!** 🚀