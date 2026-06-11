# velopack-zig

Shared build glue for using [Velopack](https://velopack.io) from Zig projects.
It wraps the Velopack runtime C API and build toolset, and builds dependencies
with zig where possible.

The Velopack release version is `0.0.1589-ga2c5a97`.

The runtime has a dependency on libgcc_s (See issue #TODO).

Velopack's cli has a dependency on .NET 9 so must be installed on the
system to use this package.

## Add this package to your zig project

```zig fetch --save "git+https://github.com/graphl-tech/velopack-zig#main"```

## Zig version

**`main` targets Zig 0.15.2** (`build.zig.zon` `minimum_zig_version`). 

## What this package provides

- **`linkVelopack(b, exe, .{ .target = target })`** — Adds the `Velopack.h` include path, picks the correct prebuilt static library for the resolved target, links Winsock + BCrypt on Windows, and sets `$ORIGIN` / `@loader_path` rpath on Linux / macOS. For `*-windows-msvc` it copies the `.lib` into a writable dir and trims Velopack’s bundled Rust `compiler_builtins-*` members (which would otherwise collide with Zig’s `compiler_rt`). Trimming uses `zig ar` from the Zig toolchain; no separate LLVM install is required. Also automatically attaches a cached `dotnet tool restore` step as a dep of the compile, so a fresh checkout / CI runner has `vpk` ready by the time you run packaging — consumers don't need to wire `addDotnetToolRestoreStep` themselves.

- **`attachMksquashfsToVpkRun(b, vpk_run, target)`** — One-call helper that wires the bundled `mksquashfs` into a `vpk pack` Run for **Linux targets** (no-op for non-Linux targets, since Velopack only needs squashfs for AppImage packaging). Internally calls `buildMksquashfs` and adds its step as a dep + prepends its bin dir to the Run's PATH. **Cross-packaging a Linux AppImage from a non-Linux host** still requires a suitable `mksquashfs` on `PATH` yourself (CI Linux runner, container, etc.) — the bundled build is host-only.

- **`buildMksquashfs(b)`** — Lower-level helper exposed for advanced uses. Builds `mksquashfs` with Zig (C compilation + bundled zlib) on **Linux hosts only**; returns `null` on macOS/Windows or when the lazy dep is not yet activated. Returns a step and `bin_dir` (under the consumer install prefix). Most consumers should use `attachMksquashfsToVpkRun` instead.

- **`addMsvcupSetupStep(b, install_dir)`** — Runs [msvcup](https://github.com/marler8997/msvcup) (via bundled scripts) to install MSVC + Windows SDK into a writable directory under the **project root** and emits Zig `--libc` manifests (`zig-libc-x64.ini`, `zig-libc-arm64.ini`).  
  - Pass `null` for `install_dir` to use `<build_root>/.velopack-msvc`.  
  - Pass e.g. `"my-msvc"` for `<build_root>/my-msvc` (and use the same string as `install_dir_name` in `resolveWindowsMsvcLibc`).

- **`resolveWindowsMsvcLibc(b, target, .{ ... })`** — Resolves the libc INI path for `*-windows-msvc`. Same behaviour on Windows and on non-Windows hosts: an explicit `-Dwindows-msvc-libc=...`-style path wins; otherwise an installed `<install_dir_name>/zig-libc-{x64,arm64}.ini` (from `msvcup-setup`) is returned, and otherwise `null` (let Zig auto-detect on Windows; explicit failure on non-Windows). Options include `explicit_path`, `install_dir_name` (must match `addMsvcupSetupStep`), and `fetch_if_missing` (returns `.needs_setup = true` so you can depend on the msvcup step before compiling). On Windows hosts that already have Visual Studio, simply don't run `msvcup-setup` and Zig's auto-detect stays in effect; running `msvcup-setup` once forces the hermetic toolchain instead.

- **`applyWindowsMsvcLibcRecursive(b, roots, libc)`** — Applies a libc INI to the executable and every `*-windows-msvc` compile reachable from it, so C dependencies (SDL, FreeType, etc.) see the same MSVC / UCRT headers and libs.

- **`addDotnetToolRestoreStep(b)`** — Returns a `Run` that executes `dotnet tool restore` in the consumer's build root. `vpk` is shipped as a .NET tool; projects pinning it via `.config/dotnet-tools.json` need this to run before `dotnet vpk …` works on a fresh checkout / CI runner. **You usually don't need to call this directly** — `linkVelopack` already attaches a cached, idempotent restore step to your compile. Exposed for consumers who want to run `dotnet tool restore` independent of linking Velopack (e.g. a top-level `tool-restore` step).

### Windows ABI note

Velopack’s Windows prebuilt is **MSVC**. Use `x86_64-windows-msvc` or `aarch64-windows-msvc` (not `*-windows-gnu`) when linking `linkVelopack` for release builds on Windows.

## Prerequisites

| Requirement | When |
|-------------|------|
| **Zig 0.15.2** | Always (see `minimum_zig_version`). |
| **[.NET SDK](https://dotnet.microsoft.com/download)** | Whenever you run **`vpk`** for packaging (`dotnet tool` / global `vpk`). Velopack’s CLI is distributed as a .NET tool; **`dotnet` is required for packaging, not for `linkVelopack` alone**. |
| **Xcode / CLT** (codesign, `notarytool`) | macOS **signed** / **notarized** releases only. |
| **Apple Developer Program** | Distribution signing + notarization. |

Install the Velopack CLI following [Velopack’s docs](https://docs.velopack.io/) — typically `dotnet tool install -g vpk` **or** a repo-local tool manifest plus `dotnet tool restore` so `dotnet vpk …` works from your project root.

Set `DOTNET_ROLL_FORWARD=Major` when running `vpk` if you use a newer runtime than the tool was built against (common in `build.zig` via `Run.setEnvironmentVariable`).

## Packaging overview (all platforms)

1. **Build** your app for the intended target (`zig build …` with the right `-Dtarget=…`).
2. **Install** or stage the built executable so `vpk` can see a directory containing the app binary and assets (Velopack expects a “pack dir”; layout depends on your integration).
3. Run **`vpk pack`** (via `dotnet vpk pack …`) with `--packId`, `--packVersion`, `--mainExe`, `--packDir`, `--outputDir`, etc.
4. **Linux AppImage / `mksquashfs`:** on a **Linux** build host, call `attachMksquashfsToVpkRun(b, vpk_run, target)` once on your `vpk` Run — it's a no-op for non-Linux targets and otherwise wires the bundled `mksquashfs` into the Run's PATH. From macOS/Windows hosts targeting Linux, ensure a compatible `mksquashfs` is on `PATH` yourself (for example run packaging on a Linux CI job).
5. **Cross-OS packaging from one machine:** when the **host OS ≠ package OS**, `vpk` needs an OS selector prefix, e.g. `vpk [win] pack …`, `vpk [linux] pack …`, `vpk [osx] pack …`, because it otherwise infers the platform from the host.

`velopack-zig` does **not** invoke `vpk` for you; your `build.zig` (or shell scripts / CI) wires the `Run` step. This keeps signing secrets and product-specific flags in **your** project.

## Windows and Linux packaging

### Windows

- Build with **`x86_64-windows-msvc`** or **`aarch64-windows-msvc`** and link with `linkVelopack`.
- On a **native Windows** dev machine with Visual Studio installed, Zig often auto-detects MSVC; you may not need a hand-written `--libc` INI.
- **Cross-compiling from macOS or Linux** to `*-windows-msvc`: you need MSVC + Windows SDK headers/libs. Run the **`msvcup-setup`** step once (see below), then point Zig at the generated `zig-libc-x64.ini` / `zig-libc-arm64.ini` (via `--libc`, `-Dwindows-msvc-libc=…`, or `applyWindowsMsvcLibcRecursive`).

### Linux

- Build your binary for `x86_64-linux-gnu` / `aarch64-linux-gnu` as usual; `linkVelopack` links the gnu `.a` and sets rpath.
- For **`vpk pack`** to produce an AppImage, **`mksquashfs` must be available**. Call `attachMksquashfsToVpkRun(b, vpk_run, target)` once on your `vpk` Run; it handles the linux-target check, lazy `mksquashfs` build, and PATH/dep wiring (example below).

## MSVC bootstrap: `msvcup-setup`

Use this when cross-compiling **to** `*-windows-msvc` **from** a non-Windows host, **or** on a Windows host where you want a hermetic toolchain tree in the repo (instead of relying on a system-wide Visual Studio install). The setup step works the same on Windows, macOS, and Linux — `setup-msvc.ps1` runs on Windows hosts and `setup-msvc.sh` runs everywhere else.

1. Expose a step in your `build.zig`:
   ```zig
   const msvcup = velopack.addMsvcupSetupStep(b, null); // or b, "my-msvc"
   const msvcup_step = b.step("msvcup-setup", "Install MSVC + WinSDK; writes zig-libc-*.ini");
   msvcup_step.dependOn(&msvcup.step);
   ```
2. Run: **`zig build msvcup-setup`** (network required; large download).
3. Outputs land under **`.velopack-msvc/`** (or your custom directory): MSVC tree + **`zig-libc-x64.ini`** / **`zig-libc-arm64.ini`**.
4. Wire **`resolveWindowsMsvcLibc`** + **`applyWindowsMsvcLibcRecursive`** (and optional `exe.step.dependOn(&msvcup.step)` when `.needs_setup`) so the main executable and all C dependencies use that INI.

If you use a custom directory, pass the **same** basename to both `addMsvcupSetupStep(b, "my-msvc")` and `resolveWindowsMsvcLibc(b, target, .{ .install_dir_name = "my-msvc", ... })`.

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

Read these with `b.graph.environ_map.get("MYAPP_MACOS_SIGN_APP")` (or `std.process.getEnv` in a small helper) and **only** add the corresponding `Run.addArg` pairs when non-null. For local dev, a **gitignored** `.env.local` plus `set -a && . ./.env.local` in your shell or IDE task is a common pattern.

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

`build.zig` (minimal linking + `vpk pack` + Linux `mksquashfs`; adjust paths and install dirs to your app):

```zig
const std = @import("std");
const velopack = @import("velopack_zig");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "myapp",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    exe.linkLibC();

    try velopack.linkVelopack(b, exe, .{ .target = target });

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

    try velopack.attachMksquashfsToVpkRun(b, vpk, target);

    vpk.step.dependOn(&exe.step);

    const install_pkg = b.addInstallDirectory(.{
        .source_dir = out,
        .install_dir = .bin,
        .install_subdir = "",
    });
    install_pkg.step.dependOn(&vpk.step);

    const desktop = b.step("desktop", "Build + pack desktop bundle");
    desktop.dependOn(&install_pkg.step);
}
```

**`*-windows-msvc` cross-build** (optional flags + setup dep): declare a `-Dfetch-msvc`-style option and wire libc like this:

```zig
const fetch_msvc = b.option(bool, "fetch-msvc", "Run msvcup before compile when libc ini missing") orelse false;
const resolved = velopack.resolveWindowsMsvcLibc(b, target, .{
    .fetch_if_missing = fetch_msvc,
    .install_dir_name = ".velopack-msvc", // default; omit if unchanged
});
if (resolved.libc_path) |ini| {
    const libc_lp: std.Build.LazyPath = .{ .cwd_relative = ini };
    velopack.applyWindowsMsvcLibcRecursive(b, &.{exe}, libc_lp);
    if (resolved.needs_setup) {
        exe.step.dependOn(&velopack.addMsvcupSetupStep(b, null).step);
    }
}

const msvcup_step = b.step("msvcup-setup", "MSVC + WinSDK → zig-libc-*.ini");
msvcup_step.dependOn(&velopack.addMsvcupSetupStep(b, null).step);
```

## License

MIT — see `LICENSE`.
