# velopack-zig

Shared build glue for using [Velopack](https://velopack.io) from Zig projects.
It wraps the Velopack runtime C API and build toolset, and builds dependencies
with zig where possible.

Velopack's CLI is a .NET tool, so the [.NET SDK](https://dotnet.microsoft.com/download)
must be installed to package.

## Add this package to your zig project

```zig fetch --save "git+https://github.com/graphl-tech/velopack-zig#main"```

## Zig version

**`main` targets Zig 0.15.2** (`build.zig.zon` `minimum_zig_version`). 

## Usage

```zig
const std = @import("std");
const velopack = @import("velopack_zig");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Gate the one thing that reaches out to the network on demand. Recommended
    // over hardcoding `true`, so a plain `zig build` is never surprising.
    const install_vpk = b.option(bool, "install-vpk", "Opt-in to installing Velopack dotnet CLI") orelse false;

    const exe = b.addExecutable(.{
        .name = "myapp",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    exe.linkLibC();

    velopack.linkVelopack(b, exe, .{ .target = target, .optimize = optimize });

    const staging = b.addWriteFiles();
    _ = staging.addCopyFile(exe.getEmittedBin(), if (target.result.os.tag == .windows) "myapp.exe" else "myapp");

    const packaged = velopack.addVelopackedAppDir(b, .{
        .name = "myapp",
        .version = "1.0.0",
        .target = target,
        .source_dir = staging.getDirectory(),
        .icon = b.path("art/icon.png"),
        .install_dir = .prefix,
        .install_subdir = "desktop",
        .install_vpk = install_vpk,
    });

    b.step("package", "Build the release bundle").dependOn(&packaged.step);
}
```

`zig build package -Dinstall-vpk=true` writes setup executables, the `.nupkg`
and the `RELEASES` feed to `zig-out/desktop/`.

### Windows ABI note

Velopack's Windows prebuilt is **MSVC**. Use `x86_64-windows-msvc` or
`aarch64-windows-msvc` (not `*-windows-gnu`).

## Customizing the `vpk` command

`addVelopackedAppDir` models the common `vpk pack` flags directly — `name`
(`--packId`), `version`, `main_exe`, `title`, `authors`, `icon`, `channel`,
`delta`. Everything else goes through:

- `extra_vpk_args: []const []const u8` — appended verbatim, e.g.
  `&.{ "--exclude", ".*\\.pdb", "--noPortable" }`.
- `extra_vpk_path_args: []const VpkPathArg` — same, but the value is a path this
  build produces, e.g. `&.{ .{ .prefix = "--releaseNotes", .path = notes } }`.
  The pack step waits on whatever generates it.
- `vpk_argv: ?[]const []const u8` — run something other than the managed `vpk`,
  e.g. `&.{ "dotnet", "vpk" }` for a repo-local `.config/dotnet-tools.json`
  (pair it with `addDotnetToolRestoreStep`).

`addVelopackStep` returns the `*std.Build.Step.Run` itself if you would rather
add arguments to it directly; `outputDir(run)` gives you the release directory.

## Testing

`test/sample/` is a minimal consumer of this package. `./test/package.sh` builds
and packages it, which is exactly what `.github/workflows/package.yml` runs on
Linux, macOS and Windows.

## Velopack documentation

- [Docs home](https://docs.velopack.io/) · [C / C++ quick start](https://docs.velopack.io/getting-started/cpp)
  — the C ABI these bindings link against · [C API reference](https://docs.velopack.io/reference/cpp)
- [`vpk` CLI reference](https://docs.velopack.io/reference/cli) — every flag
  `extra_vpk_args` can carry, per platform:
  [Windows](https://docs.velopack.io/reference/cli/content/vpk-windows) ·
  [Linux](https://docs.velopack.io/reference/cli/content/vpk-linux) ·
  [macOS](https://docs.velopack.io/reference/cli/content/vpk-osx)
- [Packaging overview](https://docs.velopack.io/packaging/overview) ·
  [Code signing](https://docs.velopack.io/packaging/signing) ·
  [Release channels](https://docs.velopack.io/packaging/channels) ·
  [Delta updates](https://docs.velopack.io/packaging/deltas) ·
  [Cross compiling](https://docs.velopack.io/packaging/cross-compiling)
- [Distributing releases](https://docs.velopack.io/distributing/overview) ·
  [Deployment CLI](https://docs.velopack.io/distributing/deploy-cli)
