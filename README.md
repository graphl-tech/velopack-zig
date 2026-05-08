# velopack-zig

Shared build glue for using [Velopack](https://velopack.io) from Zig
projects.  Wraps the prebuilt Velopack C-ABI archives and provides:

- **`linkVelopack(b, exe, .{ .target = target })`** — adds the include path,
  picks the right prebuilt static library for the resolved target, links
  Winsock + BCrypt on Windows, and sets `$ORIGIN` / `@loader_path` rpath on
  Linux / macOS.  For `*-windows-msvc` targets it copies the archive into a
  writable workspace and trims out Velopack's bundled Rust
  `compiler_builtins-*` members (which would otherwise duplicate Zig's own
  `compiler_rt` symbols at link time).  The trim step uses `zig ar` (Zig's
  bundled LLVM archiver), so no separate LLVM install is required.

- **`buildMksquashfs(b)`** — builds `mksquashfs` from the bundled
  `squashfs-tools` source tree and returns the bin dir to add to
  `vpk pack`'s PATH.  Required for the Linux AppImage step.

- **`addMsvcupSetupStep(b, install_dir)`** — runs
  [msvcup](https://github.com/marler8997/msvcup) to install MSVC + the
  Windows SDK into a writable directory and emits Zig `--libc` manifests
  (`zig-libc-x64.ini`, `zig-libc-arm64.ini`).  Used to cross-compile to
  `*-windows-msvc` from non-Windows hosts.

- **`resolveWindowsMsvcLibc(b, target, .{ ... })`** — locate the right
  libc INI for cross-builds, falling back to a fetched copy when
  `-Dfetch-msvc` is set.

- **`applyWindowsMsvcLibcRecursive(b, roots, libc)`** — apply a libc INI to
  every `*-windows-msvc` compile reachable from the given root compiles, so
  static C dependencies (SDL3, FreeType, tree-sitter, …) see the same UCRT
  / MSVC headers as the executable.

The library bundles the Velopack release zip (currently `0.0.1589-ga2c5a97`)
and `squashfs-tools` source as its own `build.zig.zon` dependencies, so
consumer projects do not need to declare either themselves.

## Zig version

Pinned to **Zig 0.15.2** for now. 

## Adding to a project

`build.zig.zon`:

```zig
.dependencies = .{
    .velopack_zig = .{
        .path = "../velopack-zig",        // or url + hash
    },
    // …
},
```

`build.zig`:

```zig
const velopack = @import("velopack_zig");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{ .name = "myapp", .root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    }) });
    exe.linkLibC();

    try velopack.linkVelopack(b, exe, .{ .target = target });

    // -- vpk pack ----------------------------------------------------
    const vpk = b.addSystemCommand(&.{ "dotnet", "vpk", "pack",
        "--packId", "myapp",
        "--packVersion", "0.1.0",
        "--mainExe", switch (target.result.os.tag) {
            .windows => "myapp.exe",
            else => "myapp",
        },
        "--delta", "None", "--yes",
    });
    vpk.addArg("--outputDir");
    const out = vpk.addOutputDirectoryArg(b.getInstallPath(.bin, "desktop"));
    vpk.addArg("--packDir");
    vpk.addDirectoryArg(exe.getEmittedBin().dirname());
    vpk.setEnvironmentVariable("DOTNET_ROLL_FORWARD", "Major");

    if (target.result.os.tag == .linux) {
        if (try velopack.buildMksquashfs(b)) |sq| {
            vpk.step.dependOn(sq.step);
            vpk.addPathDir(sq.bin_dir);
        }
    }

    const desktop = b.step("desktop", "Build full desktop app for current OS");
    desktop.dependOn(&b.addInstallDirectory(.{
        .source_dir = out,
        .install_dir = .bin,
        .install_subdir = "",
    }).step);
}
```

For `*-windows-msvc` cross-builds, declare an
`-Dfetch-msvc` option and wire the setup step:

```zig
const fetch_msvc = b.option(bool, "fetch-msvc", "Auto-install MSVC for *-windows-msvc cross-compile") orelse false;
const resolved = velopack.resolveWindowsMsvcLibc(b, target, .{ .fetch_if_missing = fetch_msvc });
if (resolved.libc_path) |ini| {
    const libc_lp: std.Build.LazyPath = .{ .cwd_relative = ini };
    velopack.applyWindowsMsvcLibcRecursive(b, &.{exe}, libc_lp);
    if (resolved.needs_setup) {
        const setup = velopack.addMsvcupSetupStep(b, null);
        exe.step.dependOn(&setup.step);
    }
}

// Always expose msvcup-setup as a top-level step.
const setup_step = b.step("msvcup-setup", "Install MSVC + Windows SDK for *-windows-msvc");
setup_step.dependOn(&velopack.addMsvcupSetupStep(b, null).step);
```

## License

MIT — see `LICENSE`.
