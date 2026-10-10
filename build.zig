//! Build script for zmp — an advanced terminal music player written in Zig.
//!
//!   zig build              compile `zmp` into zig-out/bin
//!   zig build run -- FILES play files/directories immediately
//!   zig build test         run the unit test suite
//!   zig build bench        run the DSP microbenchmarks

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ---- user-facing build options -------------------------------------
    const enable_wasapi = b.option(
        bool,
        "wasapi",
        "Build the WASAPI audio backend (Windows only, default: on for Windows)",
    ) orelse (target.result.os.tag == .windows);

    const enable_winmm = b.option(
        bool,
        "winmm",
        "Build the legacy waveOut audio backend (Windows only, default: on for Windows)",
    ) orelse (target.result.os.tag == .windows);

    const enable_mp3 = b.option(
        bool,
        "mp3",
        "Build MP3/MP2 support using the vendored minimp3 (default: on)",
    ) orelse true;

    const build_options = b.addOptions();
    build_options.addOption(bool, "enable_wasapi", enable_wasapi);
    build_options.addOption(bool, "enable_winmm", enable_winmm);
    build_options.addOption(bool, "enable_mp3", enable_mp3);
    build_options.addOption([]const u8, "version", "0.1.0");

    // ---- the library module holding all of the player's logic ----------
    const mod = b.addModule("zmp", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    mod.addOptions("build_options", build_options);

    if (enable_mp3) {
        // minimp3 is plain C; the shim in vendor/ keeps its struct layouts out
        // of the Zig side entirely.
        mod.link_libc = true;
        mod.addIncludePath(b.path("vendor/minimp3"));
        mod.addCSourceFile(.{
            .file = b.path("vendor/minimp3/zmp_mp3.c"),
            .flags = &.{
                "-std=c99",
                "-O2",
                // minimp3 is vendored unmodified; do not fail its warnings.
                "-Wno-unused-function",
                "-Wno-unused-but-set-variable",
            },
        });
    }

    if (target.result.os.tag == .windows) {
        // COM (WASAPI device enumeration) and the multimedia API (waveOut).
        if (enable_wasapi) mod.linkSystemLibrary("ole32", .{});
        if (enable_winmm) mod.linkSystemLibrary("winmm", .{});
    }

    // ---- the executable ------------------------------------------------
    const exe = b.addExecutable(.{
        .name = "zmp",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "zmp", .module = mod }},
        }),
    });
    b.installArtifact(exe);

    const run_step = b.step("run", "Run the player");
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();
    run_step.dependOn(&run_cmd.step);

    // ---- the desktop interface -----------------------------------------
    // A separate executable rather than a flag: a Windows GUI program wants
    // the windows subsystem so launching it does not open a console, and that
    // is a link-time property of the binary.
    const gui_exe = b.addExecutable(.{
        .name = "zmp-gui",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/gui_main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "zmp", .module = mod }},
        }),
    });
    if (target.result.os.tag == .windows) {
        gui_exe.root_module.linkSystemLibrary("user32", .{});
        gui_exe.root_module.linkSystemLibrary("gdi32", .{});
        gui_exe.root_module.linkSystemLibrary("shell32", .{});
        // Without this a console window flashes up alongside the player.
        gui_exe.subsystem = .windows;
        b.installArtifact(gui_exe);

        const gui_step = b.step("gui", "Run the desktop interface");
        const gui_cmd = b.addRunArtifact(gui_exe);
        gui_cmd.step.dependOn(b.getInstallStep());
        gui_cmd.addPassthruArgs();
        gui_step.dependOn(&gui_cmd.step);
    }

    // ---- tests ---------------------------------------------------------
    const mod_tests = b.addTest(.{ .root_module = mod });
    const run_mod_tests = b.addRunArtifact(mod_tests);

    const exe_tests = b.addTest(.{ .root_module = exe.root_module });
    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run the unit test suite");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);

    if (target.result.os.tag == .windows) {
        const gui_tests = b.addTest(.{ .root_module = gui_exe.root_module });
        const run_gui_tests = b.addRunArtifact(gui_tests);
        test_step.dependOn(&run_gui_tests.step);
    }

    // ---- benchmarks ----------------------------------------------------
    const bench = b.addExecutable(.{
        .name = "zmp-bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/bench.zig"),
            .target = target,
            .optimize = .ReleaseFast,
            .imports = &.{.{ .name = "zmp", .module = mod }},
        }),
    });
    const bench_step = b.step("bench", "Run DSP microbenchmarks");
    const run_bench = b.addRunArtifact(bench);
    run_bench.addPassthruArgs();
    bench_step.dependOn(&run_bench.step);
}
