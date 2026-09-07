//! Smallest app that exercises velopack-zig end to end: link the runtime, stage
//! a payload, package it. `test/package.sh` builds this on every CI platform.
const std = @import("std");
const velopack = @import("velopack_zig");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const install_vpk = b.option(bool, "install-vpk", "Opt-in to installing Velopack dotnet CLI") orelse false;

    const exe = b.addExecutable(.{
        .name = "velosample",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    exe.linkLibC();

    velopack.linkVelopack(b, exe, .{ .target = target, .optimize = optimize });

    b.installArtifact(exe);
    const run = b.addRunArtifact(exe);
    b.step("run", "Run the sample").dependOn(&run.step);

    const staging = b.addWriteFiles();
    _ = staging.addCopyFile(
        exe.getEmittedBin(),
        if (target.result.os.tag == .windows) "velosample.exe" else "velosample",
    );

    const notes = b.addWriteFiles().add("release-notes.md", "## 1.0.0\n\n- First release.\n");

    const packaged = velopack.addVelopackedAppDir(b, .{
        .name = "velosample",
        .version = "1.0.0",
        .title = "Velopack Zig Sample",
        .authors = "velopack-zig",
        .target = target,
        .source_dir = staging.getDirectory(),
        .install_dir = .prefix,
        .install_subdir = "desktop",
        .install_vpk = install_vpk,
        // Covers the two escape hatches for flags this wrapper doesn't model.
        .extra_vpk_args = &.{ "--exclude", ".*\\.pdb" },
        .extra_vpk_path_args = &.{.{ .prefix = "--releaseNotes", .path = notes }},
    });

    b.step("package", "Build the release bundle").dependOn(&packaged.step);
}
