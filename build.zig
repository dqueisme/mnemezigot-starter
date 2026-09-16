const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // 1. Dependency to Mnemezigot Framework
    const mn_dep = b.dependency("mnemezigot", .{
        .target = target,
        .optimize = optimize,
    });

    // 2. Build Frontend WASM module (ReleaseSmall < 10 KB, stripped)
    const wasm_target = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .freestanding,
    });

    const wasm = b.addExecutable(.{
        .name = "app",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/client.zig"),
            .target = wasm_target,
            .optimize = .ReleaseSmall,
            .strip = true,
        }),
    });
    wasm.root_module.addImport("mnemezigot_client", mn_dep.module("mnemezigot_client"));
    wasm.entry = .disabled;
    wasm.rdynamic = true;

    // Install WASM to public/app.wasm and zig-out/public/app.wasm
    const install_wasm_dev = b.addInstallArtifact(wasm, .{
        .dest_dir = .{ .override = .{ .custom = "../public" } },
    });
    const install_wasm_dist = b.addInstallArtifact(wasm, .{
        .dest_dir = .{ .override = .{ .custom = "public" } },
    });

    // Install static HTML/CSS/JS files to zig-out/public/
    b.installFile("public/index.html", "public/index.html");
    b.installFile("public/style.css", "public/style.css");
    b.installFile("public/bridge.js", "public/bridge.js");

    // 3. Build Backend Server
    const server = b.addExecutable(.{
        .name = "server",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .strip = if (optimize != .Debug) true else false,
        }),
    });

    // Import Mnemezigot framework module into server
    server.root_module.addImport("mnemezigot", mn_dep.module("mnemezigot"));

    const install_server = b.addInstallArtifact(server, .{
        .dest_dir = .{ .override = .{ .custom = "" } },
    });

    b.getInstallStep().dependOn(&install_server.step);
    b.getInstallStep().dependOn(&install_wasm_dist.step);
    b.getInstallStep().dependOn(&install_wasm_dev.step);

    // 4. Run step (`zig build run`)
    const run_cmd = b.addRunArtifact(server);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run the application");
    run_step.dependOn(&run_cmd.step);
}
