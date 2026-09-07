# velopack-zig

Shared build glue for using [Velopack](https://velopack.io) from Zig projects.
It wraps the Velopack runtime C API and build toolset, and builds dependencies
with zig where possible.

Two calls in your `build.zig` cover the whole flow: `linkVelopack` puts the
Velopack runtime into your executable, `addVelopackedAppDir` turns a staged
directory into an installed release bundle. Everything they need — the `vpk`
CLI, MSVC + the Windows SDK for cross-compiled Windows builds, `mksquashfs` for
Linux AppImages — is provisioned by this package.

The Velopack release version is `0.0.1589-ga2c5a97`.

The runtime has a dependency on libgcc_s (See issue #TODO).

Velopack's CLI is a .NET tool, so the [.NET SDK](https://dotnet.microsoft.com/download)
must be installed to package (not to link).

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
    const install_vpk = b.option(bool, "install-vpk", "Download the Velopack CLI into .velopack-tools/ when missing") orelse false;

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

    // Stage exactly what ships. Everything in this directory ends up in the
    // bundle, so don't point at a directory of build leftovers.
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

## `linkVelopack(b, compile, opts)`

Adds the `Velopack.h` include path, picks the correct prebuilt static library
for the resolved target, links Winsock + BCrypt on Windows, and sets `$ORIGIN` /
`@loader_path` rpath on Linux / macOS. For `*-windows-msvc` it copies the `.lib`
into a writable dir and trims Velopack's bundled Rust `compiler_builtins-*`
members, which would otherwise collide with Zig's `compiler_rt`. Trimming uses
`zig ar` from the Zig toolchain; no separate LLVM install is required.

| Option | Default | Meaning |
|--------|---------|---------|
| `target` | — | The resolved target you are building for. |
| `optimize` | — | The optimize mode you are building with. |
| `handle_libc` | `true` | Take care of MSVC + the Windows SDK for `*-windows-msvc` (see below). No effect on other targets. |
| `windows_msvc_libc` | `null` | An explicit Zig `--libc` manifest, overriding both the command-line `--libc` and the managed toolchain. |
| `msvc_dir` | `".velopack-msvc"` | Where the managed MSVC tree and its `zig-libc-*.ini` live, relative to your build root. |

### `handle_libc`

Zig can cross-compile to `*-windows-msvc` — the ABI Velopack's Windows build
requires — but only with MSVC and Windows SDK headers and libraries on hand.
With `handle_libc` set (the default), velopack-zig resolves a `--libc` manifest
in this order:

1. `opts.windows_msvc_libc`.
2. The build's own `--libc`. It is then *scoped* to the `*-windows-msvc`
   compiles — left as `b.libc_file` it would also be handed to host-side build
   tools, which breaks them.
3. `<build_root>/<msvc_dir>/zig-libc-{x64,arm64}.ini`, if it exists.
4. On a **Windows host**: nothing, leaving Zig's Visual Studio auto-detect in
   play. Run `msvcup-setup` once (below) to force the managed toolchain instead.
5. Otherwise: install MSVC + the Windows SDK with
   [msvcup](https://github.com/marler8997/msvcup) before compiling. This is a
   large one-time download.

Whatever it lands on is applied to your executable **and every `*-windows-msvc`
compile it links**, so C dependencies (SDL, FreeType, tree-sitter, …) see the
same UCRT and MSVC headers.

Call `linkVelopack` after wiring your executable's dependencies — it walks the
compile graph as it exists at that point.

Set `handle_libc = false` to do all of this yourself; `resolveWindowsMsvcLibc`,
`addMsvcupSetupStep` and `applyWindowsMsvcLibcRecursive` stay available for that.

### Windows ABI note

Velopack's Windows prebuilt is **MSVC**. Use `x86_64-windows-msvc` or
`aarch64-windows-msvc` (not `*-windows-gnu`).

## `addVelopackedAppDir(b, opts)`

Runs `vpk pack` over a staged directory and installs the release artifacts,
returning the `*std.Build.Step.InstallDir` so you can hang your own `package`
step off it. `install_dir` and `install_subdir` mean what they do in
`b.addInstallDirectory`.

| Option | Default | `vpk` flag |
|--------|---------|-----------|
| `name` | — | `--packId` |
| `version` | — | `--packVersion` |
| `source_dir` | — | `--packDir` |
| `target` | — | picks the `[win]`/`[osx]`/`[linux]` selector, the `--mainExe` extension and whether mksquashfs is needed |
| `main_exe` | `name` (+ `.exe` on Windows) | `--mainExe` |
| `title` | `null` | `--packTitle` |
| `authors` | `null` | `--packAuthors` |
| `icon` | `null` | `--icon` |
| `channel` | `null` | `--channel` |
| `delta` | `"None"` | `--delta` |
| `extra_args` | `&.{}` | appended verbatim — signing identities, `--releaseNotes`, anything not modelled here |
| `depends_on` | `&.{}` | steps that must finish before `vpk pack` runs |
| `install_dir` / `install_subdir` | `.prefix` / `""` | where the release artifacts are installed |

`source_dir` already orders the pack run after whatever produced it. `depends_on`
is for work that touches the staged payload without being its producer — running
`strip` over the staged binary, for instance.

### Getting the `vpk` CLI

velopack-zig runs `vpk` out of `<build_root>/.velopack-tools`, a `dotnet tool
--tool-path` install it manages itself. You do not need a
`.config/dotnet-tools.json`.

| Option | Default | Meaning |
|--------|---------|---------|
| `install_vpk` | `false` | Allow installing `vpk` when it is missing or the wrong version. When false, that situation is a build error explaining what to run. |
| `vpk_version` | `.bundled` | `.bundled` (the release this package's runtime comes from), `.latest` (newest stable on NuGet), or `.{ .pinned = "1.2.0" }`. |
| `vpk_dir` | `".velopack-tools"` | Where the managed install lives, relative to your build root. |
| `vpk_argv` | `null` | Run something else entirely, e.g. `&.{ "dotnet", "vpk" }` for a repo-local tool manifest. Disables the managed install. |

Wire `install_vpk` to a build option rather than hardcoding `true`, so a plain
`zig build` never downloads anything:

```zig
.install_vpk = b.option(bool, "install-vpk", "Download the Velopack CLI when missing") orelse false,
```

`vpk` stamps its own updater binaries into the bundle, so the CLI and the linked
runtime should come from the same Velopack release — hence `.bundled` as the
default rather than `.latest`. Add `.velopack-tools/` to your `.gitignore`.

> **TODO:** when resolving `.latest`, skip releases younger than five days, so a
> broken publish upstream can't take builds down with it.

## Escape hatches

`linkVelopack` and `addVelopackedAppDir` drive all of these; they stay public
for consumers doing something the options above don't cover.

- **`addVelopackStep(b, opts)`** — the `vpk pack` `Run` on its own, taking every
  option `addVelopackedAppDir` does except `install_dir` / `install_subdir`.
  Pair it with **`outputDir(run)`** for the release directory as a `LazyPath`.
  Use it when you want to do something with that directory other than install it.

- **`addMsvcupSetupStep(b, install_dir)`** — installs MSVC + the Windows SDK
  into `<build_root>/<install_dir>` (`null` → `.velopack-msvc`) and emits
  `zig-libc-x64.ini` / `zig-libc-arm64.ini`. Cached per build root and
  directory, so exposing it as your own step and letting `linkVelopack` depend on
  it yields one install, not two:

  ```zig
  const msvcup_step = b.step("msvcup-setup", "MSVC + WinSDK → zig-libc-*.ini");
  msvcup_step.dependOn(&velopack.addMsvcupSetupStep(b, null).step);
  ```

  This is also how a **Windows host without Visual Studio** opts into the managed
  toolchain: run it once, and `handle_libc` picks the manifest up from then on.

- **`resolveWindowsMsvcLibc(b, target, opts)`** — locates the `zig-libc-*.ini`
  for a `*-windows-msvc` target without applying it.

- **`applyWindowsMsvcLibcRecursive(b, roots, libc)`** — applies a manifest to
  every `*-windows-msvc` compile reachable from `roots`.

- **`buildMksquashfs(b)`** / **`attachMksquashfsToVpkRun(b, run, target)`** —
  build `mksquashfs` with Zig (upstream squashfs-tools + zlib) and put it on a
  `vpk` Run's `PATH`. `addVelopackStep` already does this for Linux targets.
  **Linux hosts only**: returns `null` elsewhere, and on the first build before
  the lazy `squashfs` dependency has been fetched (Zig prints a `--fetch` hint).
  Cross-packaging a Linux AppImage from macOS or Windows needs a `mksquashfs` on
  `PATH` yourself — a Linux CI job or container is the usual answer.

- **`addDotnetToolRestoreStep(b)`** — `dotnet tool restore` in your build root,
  for projects that pin `vpk` in their own `.config/dotnet-tools.json` and pass
  `.vpk_argv = &.{ "dotnet", "vpk" }`.

## Prerequisites

| Requirement | When |
|-------------|------|
| **Zig 0.15.2** | Always (see `minimum_zig_version`). |
| **[.NET SDK](https://dotnet.microsoft.com/download)** | Packaging. Velopack's CLI is a .NET tool; `dotnet` is **not** needed for `linkVelopack` alone. |
| **Network access** | First `-Dinstall-vpk=true`, and the first `*-windows-msvc` cross-build (MSVC + Windows SDK). Both cache into your build root. |
| **Xcode / CLT** (codesign, `notarytool`) | macOS **signed** / **notarized** releases only. |
| **Apple Developer Program** | Distribution signing + notarization. |

## Cross-OS packaging

`vpk` infers the target platform from the host, so `addVelopackStep` passes an
explicit `[win]` / `[linux]` / `[osx]` selector whenever the target OS differs
from the host's. Verified from a Linux host: `x86_64-linux-gnu`,
`aarch64-linux-gnu`, `x86_64-windows-msvc` and `aarch64-windows-msvc` all
package end to end. Two gaps are the host's, not this package's:

- **macOS targets can only be packaged on macOS.** `vpk` itself refuses:
  *"Cross-compiling from Linux to MacOS is not supported."* Signing and
  notarization need Apple tooling anyway.
- **Linux AppImages** need `mksquashfs`. It is built for you on a Linux host; on
  macOS or Windows hosts, put one on `PATH`.

### Case-sensitive filesystems

The Windows SDK ships `Windows.h` and `kernel32.Lib`, its own headers include
`windows.h` and `DriverSpecs.h`, and linker directives ask for `LIBCMT.lib`. On
Windows and macOS the filesystem papers over that; on Linux nothing resolves. The
`msvcup-setup` step therefore does an `xwin`-style pass over the installed tree,
reading every header and symlinking each spelling it actually references, plus
all-lowercase and uppercase-stem aliases for the libraries. It runs once per
install (marked by `.zig-case-aliases` in the install root) and takes a few
seconds.

## macOS packaging, code signing, and notarization

Velopack’s **`vpk pack`** can drive **codesign** and **notarytool** when you pass the right flags. **No passwords or App Store Connect keys belong in git** — use the **macOS Keychain** and environment variables (or local-only files) that **your** `build.zig` reads into `Run` arguments.

### One-time Apple / machine setup

1. **Enroll** in the Apple Developer Program (distribution builds).
2. **Create / download** certificates (commonly **Developer ID Application** for the `.app`, **Developer ID Installer** for the installer package) and install them in **Keychain Access**.
3. **Notarytool credentials:** store a profile in the keychain, e.g.  
   `xcrun notarytool store-credentials <profile-name> --apple-id "…" --team-id … --password …`  
   (prefer an **app-specific password** or **API key** per Apple’s current guidance — see `notarytool help store-credentials`).
4. **Entitlements:** for **hardened runtime** + **notarization**, use an **`.entitlements`** file (real extension required). Typical needs for mixed native/JIT stacks include keys such as `com.apple.security.cs.allow-jit` / `allow-unsigned-executable-memory` / `disable-library-validation` — exact keys are **app-specific**; validate against Apple’s docs and your threat model.
5. **`Info.plist`:** ensure bundle metadata is correct (`CFBundleExecutable`, `CFBundlePackageType` = `APPL`, etc.) or Gatekeeper / `spctl` may reject the bundle even if binaries are signed.

### Wiring secrets from the environment (recommended)

Your consumer project can map env vars to `vpk` flags **without** committing values, for example:

| Purpose | Typical env var (examples) | `vpk` flag |
|---------|---------------------------|------------|
| Sign the app bundle | `MYAPP_MACOS_SIGN_APP` | `--signAppIdentity` |
| Installer identity | `MYAPP_MACOS_SIGN_INSTALLER` | `--signInstallIdentity` |
| Notarytool profile | `MYAPP_MACOS_NOTARY_PROFILE` | `--notaryProfile` |

Read these in your `build.zig` (`std.process.getEnvVarOwned`, or a small helper)
and pass the flags through `extra_args` only when they are set:

```zig
var signing: std.ArrayList([]const u8) = .empty;
if (std.process.getEnvVarOwned(b.allocator, "MYAPP_MACOS_SIGN_APP")) |id| {
    try signing.appendSlice(b.allocator, &.{ "--signAppIdentity", id });
} else |_| {}

const packaged = velopack.addVelopackedAppDir(b, .{
    // …
    .extra_args = signing.items,
});
```

For local dev, a **gitignored** `.env.local` plus `set -a && . ./.env.local` in your shell or IDE task is a common pattern.

### Order of operations

Unsigned `vpk pack` can work for local testing. For release: build **ReleaseFast** (or equivalent) → **`vpk pack`** with signing + entitlements → notarization (via `--notaryProfile`) → staple if required. Consult [Velopack’s macOS documentation](https://docs.velopack.io/) for the exact `vpk` flags your version supports.

## Example: `build.zig` (Zig 0.15.2)

`build.zig.zon`:

```zig
.dependencies = .{
    .velopack_zig = .{
        .path = "../velopack-zig", // or .url + .hash
    },
    // …
},
```

See [Usage](#usage) above for the `build.zig` side. A real project usually adds
a couple of things to it:

```zig
// Package for every shipping triple in one command.
const packageall = b.step("packageall", "Package every release triple");
for ([_][]const u8{
    "x86_64-linux-gnu",  "aarch64-linux-gnu",
    "x86_64-macos",      "aarch64-macos",
    "x86_64-windows-msvc", "aarch64-windows-msvc",
}) |triple| {
    const run = b.addSystemCommand(&.{
        b.graph.zig_exe, "build", "package",
        b.fmt("-Dtarget={s}", .{triple}),
        b.fmt("-Doptimize={s}", .{@tagName(optimize)}),
    });
    if (install_vpk) run.addArg("-Dinstall-vpk=true");
    run.setCwd(b.path("."));
    packageall.dependOn(&run.step);
}

// Strip the staged binary before it is packed. `strip` can't read foreign
// object files, so skip it when packaging across operating systems.
const strip = b.addSystemCommand(&.{
    if (target.result.os.tag == b.graph.host.result.os.tag) "strip" else "touch",
});
strip.addFileArg(staged_exe);
// … then pass `.depends_on = &.{&strip.step}` to addVelopackedAppDir.
```

## License

MIT — see `LICENSE`.
