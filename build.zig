//! velopack-zig — shared Velopack packaging glue for Zig projects.
//!
//! Public API (call from a consumer's build.zig):
//!
//!   const velopack = @import("velopack_zig");
//!
//!   try velopack.linkVelopack(b, exe, .{ .target = target });
//!
//!   // Linux AppImage build: returns a step + bin dir for vpk's PATH.
//!   const sq = try velopack.buildMksquashfs(b);
//!   vpk_run.step.dependOn(sq.step);
//!   vpk_run.addPathDir(sq.bin_dir);
//!
//!   // *-windows-msvc cross-compile from non-Windows hosts.
//!   const msvcup = velopack.addMsvcupSetupStep(b, null);
//!   const msvcup_step = b.step("msvcup-setup", "...");
//!   msvcup_step.dependOn(&msvcup.step);
//!
//! The library bundles the Velopack release zip and a Zig build of
//! mksquashfs (upstream squashfs-tools + zlib) as its own zon dependencies,
//! so consumer projects do not need to declare them themselves.
//!
//! **Linux host only** for `buildMksquashfs`: mksquashfs is built with the Zig
//! toolchain (no `make`). On other hosts this returns `null`; put a host
//! `mksquashfs` on `PATH` yourself if you run `vpk pack` for Linux from there.
//!
//! Targets **Zig 0.15.2** on `main`.

const std = @import("std");
const builtin = @import("builtin");

/// No-op `pub fn build` — velopack-zig produces no install artifacts of its
/// own. The exposed helpers below are invoked from the consumer's build.zig.
pub fn build(b: *std.Build) void {
    _ = b;
}

// ---------------------------------------------------------------------------
// Internal: get our own builder so we can resolve OUR zon's deps and source
// files regardless of who's calling.
// ---------------------------------------------------------------------------

fn ownBuilder(b: *std.Build) *std.Build {
    return b.dependencyFromBuildZig(@This(), .{}).builder;
}

// Per-build cache of the trim-velopack-lib host tool.
var trim_velopack_tool: ?*std.Build.Step.Compile = null;

// Per-consumer-builder cache of the `dotnet tool restore` Run, so multiple
// linkVelopack/addVpkPack callsites share a single restore step.
var dotnet_restore_cache: std.AutoHashMapUnmanaged(*std.Build, *std.Build.Step.Run) = .{};

fn cachedDotnetToolRestore(b: *std.Build) *std.Build.Step.Run {
    const gop = dotnet_restore_cache.getOrPut(b.allocator, b) catch @panic("OOM");
    if (!gop.found_existing) gop.value_ptr.* = addDotnetToolRestoreStep(b);
    return gop.value_ptr.*;
}

fn trimVelopackLibTool(own: *std.Build) *std.Build.Step.Compile {
    if (trim_velopack_tool) |t| return t;
    const t = own.addExecutable(.{
        .name = "trim-velopack-lib",
        .root_module = own.createModule(.{
            .root_source_file = own.path("tools/trim_velopack_lib.zig"),
            .target = own.graph.host,
            .optimize = .Debug,
        }),
    });
    trim_velopack_tool = t;
    return t;
}

// ---------------------------------------------------------------------------
// linkVelopack — add include path + correct prebuilt static lib + Windows
// ws2_32/bcrypt + macOS @loader_path / Linux $ORIGIN rpath. For *-windows-msvc
// the lib is copied into a writable dir and trimmed of duplicate
// `compiler_builtins-*` members (Velopack ships Rust libs that collide with
// Zig's compiler_rt at link time).  Trimming uses `zig ar` (LLVM's archiver,
// bundled with the Zig toolchain) — no separate LLVM install required.
// ---------------------------------------------------------------------------

pub const LinkVelopackOptions = struct {
    /// Target the consumer is building for.
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
};

pub fn linkVelopack(
    b: *std.Build,
    compile: *std.Build.Step.Compile,
    opts: LinkVelopackOptions,
) !void {
    const own = ownBuilder(b);
    const velopack_dep = own.dependency("velopack", .{});
    const target = opts.target;

    compile.root_module.addIncludePath(velopack_dep.path("include"));

    const lib_name = switch (target.result.os.tag) {
        .linux => switch (target.result.cpu.arch) {
            .x86_64 => "velopack_libc_linux_x64_gnu.a",
            .aarch64 => "velopack_libc_linux_arm64_gnu.a",
            else => @panic("velopack-zig: unsupported linux arch"),
        },
        .macos => switch (target.result.cpu.arch) {
            .x86_64 => "velopack_libc_osx_x64_gnu.a",
            .aarch64 => "velopack_libc_osx_arm64_gnu.a",
            else => @panic("velopack-zig: unsupported macos arch"),
        },
        .windows => switch (target.result.cpu.arch) {
            .x86_64 => "velopack_libc_win_x64_msvc.lib",
            .aarch64 => "velopack_libc_win_arm64_msvc.lib",
            .x86 => "velopack_libc_win_x86_msvc.lib",
            else => @panic("velopack-zig: unsupported windows arch"),
        },
        else => @panic("velopack-zig: unsupported OS"),
    };
    const lib_src = velopack_dep.path(b.fmt("lib-static/{s}", .{lib_name}));

    if (target.result.os.tag == .windows and target.result.abi == .msvc) {
        // Copy the read-only dep file into a writable WriteFiles output, then
        // trim it in place using `zig ar` (Zig's bundled LLVM archiver).
        const wf = b.addWriteFiles();
        const lib_copy = wf.addCopyFile(lib_src, lib_name);
        const trim = b.addRunArtifact(trimVelopackLibTool(own));
        trim.addArg(b.graph.zig_exe);
        trim.addFileArg(lib_copy);
        trim.step.dependOn(&wf.step);
        compile.root_module.addObjectFile(lib_copy);
        compile.step.dependOn(&trim.step);
    } else {
        compile.root_module.addObjectFile(lib_src);
    }

    if (target.result.os.tag == .windows) {
        // Velopack's Rust core (ureq, getrandom, TLS) needs Winsock + BCrypt.
        compile.root_module.linkSystemLibrary("ws2_32", .{});
        compile.root_module.linkSystemLibrary("bcrypt", .{});
    }
    switch (target.result.os.tag) {
        .linux => {
            compile.root_module.addRPathSpecial("$ORIGIN");
            // velopack_libc.a is built with panic=abort, but Rust std still
            // references unwinding/backtrace symbols. libgcc_s provides the
            // _Unwind_* personality + backtrace API that rustc auto-links.
            compile.root_module.linkSystemLibrary("gcc_s", .{});
        },
        .macos => compile.root_module.addRPathSpecial("@loader_path"),
        else => {},
    }

    // Velopack's `vpk` is a .NET tool pinned via .config/dotnet-tools.json;
    // packaging fails on a fresh checkout / CI runner without `dotnet tool
    // restore`. Attach a cached, idempotent restore Run to the compile so
    // consumers don't have to wire it themselves. Cheap when already restored.
    compile.step.dependOn(&cachedDotnetToolRestore(b).step);
}

// ---------------------------------------------------------------------------
// buildMksquashfs — build mksquashfs via the bundled Zig squashfs package
// (upstream squashfs-tools + zlib) and return its bin dir for vpk pack's PATH.
//
// Returns null in two cases (callers should treat both the same — fall back
// to whatever `mksquashfs` is on PATH, or skip AppImage packaging):
//
//   1. The host OS doesn't build mksquashfs (Windows). Velopack does not need
//      squashfs there.
//   2. The bundled squashfs-tools source is a **lazy dependency** that hasn't
//      been fetched yet. Zig's build runner prints a "run with --fetch"
//      hint on the first build; subsequent builds resolve normally.
//
// Wire the returned step as a dependency of your `vpk pack` Run, and pass
// `bin_dir` to `Run.addPathDir(...)` so vpk picks up the bundled mksquashfs.
// ---------------------------------------------------------------------------

pub const MksquashfsBuild = struct {
    /// Wire as a dependency of the consumer's vpk pack run step.
    step: *std.Build.Step,
    /// Pass to `Run.addPathDir(...)` so vpk finds mksquashfs.
    bin_dir: []const u8,
};

/// Build the bundled mksquashfs for Linux AppImage packaging.
///
/// Returns null on hosts that don't build squashfs (Windows) and on the very
/// first build before the lazy `squashfs` dependency has been fetched (Zig's
/// build runner will then prompt the user to re-run with `--fetch`). Either
/// way, callers can simply skip wiring `bin_dir` into the vpk Run and rely on
/// a host `mksquashfs` if one is on `PATH`.
pub fn buildMksquashfs(b: *std.Build) !?MksquashfsBuild {
    const own = ownBuilder(b);
    if (own.graph.host.result.os.tag == .windows)
        return null;

    const dep = own.lazyDependency("squashfs", .{
        .target = own.graph.host,
        .optimize = .ReleaseFast,
    }) orelse return null;

    const mksquashfs_art = dep.artifact("mksquashfs");
    const install_mksquashfs = b.addInstallArtifact(mksquashfs_art, .{
        .dest_dir = .{ .override = .{ .custom = "velopack-mksquashfs" } },
    });

    return MksquashfsBuild{
        .step = &install_mksquashfs.step,
        .bin_dir = b.getInstallPath(.{ .custom = "velopack-mksquashfs" }, ""),
    };
}

/// Wire the bundled mksquashfs into a `vpk pack` Run for Linux targets.
///
/// No-op for non-Linux targets: vpk only needs squashfs when packaging a Linux
/// AppImage. On Linux targets this builds mksquashfs (lazily — first build
/// prompts the user to `--fetch`) and prepends its bin dir to the Run's PATH.
///
/// Consumers should call this on every vpk Run; velopack-zig handles the
/// target-os check internally so the consumer doesn't have to.
pub fn attachMksquashfsToVpkRun(
    b: *std.Build,
    run: *std.Build.Step.Run,
    target: std.Build.ResolvedTarget,
) !void {
    if (target.result.os.tag != .linux) return;
    const built = (try buildMksquashfs(b)) orelse return;
    run.addPathDir(built.bin_dir);
    run.step.dependOn(built.step);
}

// ---------------------------------------------------------------------------
// addMsvcupSetupStep — install MSVC + Windows SDK into a writable directory
// and emit zig-libc-{x64,arm64}.ini, all from the bundled tools/setup-msvc.sh
// (or .ps1 on Windows hosts).
// ---------------------------------------------------------------------------

/// Returns the *Run for the platform-appropriate setup script. The consumer
/// can wire it as a dependency of `b.step("msvcup-setup", ...)` or as a
/// pre-step of compiles for *-windows-msvc cross-builds.
///
/// `install_dir` is the absolute or build-root-relative directory where the
/// MSVC tree + zig-libc-*.ini will be written. Pass null to use
/// `<build_root>/.velopack-msvc`.
pub fn addMsvcupSetupStep(b: *std.Build, install_dir: ?[]const u8) *std.Build.Step.Run {
    const own = ownBuilder(b);

    const resolved_install_dir: []const u8 = if (install_dir) |p|
        if (std.fs.path.isAbsolute(p)) b.dupePath(p) else b.pathFromRoot(p)
    else
        b.pathFromRoot(".velopack-msvc");

    const env_path = own.path("tools/msvcup.env").getPath3(b, null).toString(b.allocator) catch |e|
        std.debug.panic("velopack-zig: resolve msvcup.env: {}", .{e});
    const gen_path = own.path("tools/gen_zig_libc_msvc.zig").getPath3(b, null).toString(b.allocator) catch |e|
        std.debug.panic("velopack-zig: resolve gen_zig_libc_msvc.zig: {}", .{e});

    const run: *std.Build.Step.Run = switch (builtin.os.tag) {
        .windows => blk: {
            const script_path = own.path("tools/setup-msvc.ps1").getPath3(b, null).toString(b.allocator) catch |e|
                std.debug.panic("velopack-zig: resolve setup-msvc.ps1: {}", .{e});
            const r = b.addSystemCommand(&.{
                "powershell", "-NoProfile", "-ExecutionPolicy",   "Bypass",
                "-File",      script_path,  resolved_install_dir,
            });
            break :blk r;
        },
        else => blk: {
            const script_path = own.path("tools/setup-msvc.sh").getPath3(b, null).toString(b.allocator) catch |e|
                std.debug.panic("velopack-zig: resolve setup-msvc.sh: {}", .{e});
            const r = b.addSystemCommand(&.{ "bash", script_path, resolved_install_dir });
            break :blk r;
        },
    };
    run.setEnvironmentVariable("VELOPACK_ZIG_ENV_FILE", env_path);
    run.setEnvironmentVariable("VELOPACK_ZIG_GEN_SCRIPT", gen_path);
    run.setEnvironmentVariable("VELOPACK_ZIG_ZIG", b.graph.zig_exe);
    return run;
}

// ---------------------------------------------------------------------------
// resolveWindowsMsvcLibc — locate the right zig-libc-*.ini for *-windows-msvc.
// Resolution order (host-agnostic — same behaviour on Windows and on
// non-Windows hosts that cross-compile to *-windows-msvc):
//   1. explicit_path (e.g. -Dwindows-msvc-libc=)
//   2. <build_root>/<install_dir_name>/zig-libc-{x64,arm64}.ini if it exists
//   3. when fetch_if_missing=true and the file is absent: returns the would-be
//      path with .needs_setup = true; caller should attach msvcup-setup as a
//      dep of compile.
// Returns null when nothing is configured. On native Windows hosts that lets
// Zig fall back to auto-detecting an installed Visual Studio (preferred when
// the developer already has it). To force the msvcup-installed SDK on a
// Windows host instead, run `msvcup-setup` once or pass -Dfetch-msvc — the
// existence of <install_dir_name>/zig-libc-*.ini wins over auto-detect.
// ---------------------------------------------------------------------------

pub const ResolveWindowsMsvcLibcOptions = struct {
    explicit_path: ?[]const u8 = null,
    install_dir_name: []const u8 = ".velopack-msvc",
    fetch_if_missing: bool = false,
};

pub const ResolvedWindowsMsvcLibc = struct {
    libc_path: ?[]const u8,
    needs_setup: bool,
};

pub fn resolveWindowsMsvcLibc(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    opts: ResolveWindowsMsvcLibcOptions,
) ResolvedWindowsMsvcLibc {
    if (target.result.os.tag != .windows or target.result.abi != .msvc)
        return .{ .libc_path = null, .needs_setup = false };

    if (opts.explicit_path) |p| {
        const abs = if (std.fs.path.isAbsolute(p)) b.dupePath(p) else b.pathFromRoot(p);
        return .{ .libc_path = abs, .needs_setup = false };
    }

    const arch_suffix: []const u8 = switch (target.result.cpu.arch) {
        .x86_64 => "x64",
        .aarch64 => "arm64",
        else => return .{ .libc_path = null, .needs_setup = false },
    };
    const rel = b.fmt("{s}/zig-libc-{s}.ini", .{ opts.install_dir_name, arch_suffix });

    const exists = blk: {
        b.build_root.handle.access(rel, .{}) catch break :blk false;
        break :blk true;
    };

    // Same behaviour on Windows and non-Windows hosts: an installed
    // <install_dir_name>/ tree (or -Dfetch-msvc) wins; otherwise return null
    // and let the caller decide (Zig auto-detect on Windows; explicit failure
    // on non-Windows hosts that can't auto-detect).
    if (exists) {
        return .{ .libc_path = b.pathFromRoot(rel), .needs_setup = false };
    }
    if (opts.fetch_if_missing) {
        return .{ .libc_path = b.pathFromRoot(rel), .needs_setup = true };
    }
    return .{ .libc_path = null, .needs_setup = false };
}

// ---------------------------------------------------------------------------
// addDotnetToolRestoreStep — `dotnet tool restore` in the consumer build root.
// Velopack's `vpk` is shipped as a .NET tool; projects that pin it via a
// repo-local `.config/dotnet-tools.json` need to run `dotnet tool restore`
// before `dotnet vpk pack ...` will work. Wire this Run as a dependency of
// your vpk Run (or of the first iteration of a packageall sequence) so a
// fresh checkout / CI runner doesn't fail with "tool not found".
// ---------------------------------------------------------------------------

/// Returns a Run that executes `dotnet tool restore` in the consumer's build
/// root. Idempotent and cheap when the tools are already restored.
pub fn addDotnetToolRestoreStep(b: *std.Build) *std.Build.Step.Run {
    const r = b.addSystemCommand(&.{ "dotnet", "tool", "restore" });
    r.setCwd(b.path("."));
    return r;
}

// ---------------------------------------------------------------------------
// applyWindowsMsvcLibcRecursive — apply a zig-libc INI to every reachable
// *-windows-msvc compile (exe + every static lib it links). Without this,
// dependencies such as SDL/FreeType/tree-sitter don't see the same UCRT/MSVC
// headers as the exe and fail to compile their C sources.
// ---------------------------------------------------------------------------

pub fn applyWindowsMsvcLibcRecursive(
    b: *std.Build,
    roots: []const *std.Build.Step.Compile,
    libc_lp: std.Build.LazyPath,
) void {
    var seen = std.AutoHashMap(*std.Build.Step.Compile, void).init(b.allocator);
    defer seen.deinit();
    for (roots) |root| {
        const compiles = std.Build.Step.Compile.getCompileDependencies(root, true);
        for (compiles) |c| {
            const gop = seen.getOrPut(c) catch @panic("OOM");
            if (gop.found_existing) continue;
            const rt = c.root_module.resolved_target orelse continue;
            if (rt.result.os.tag == .windows and rt.result.abi == .msvc) {
                c.setLibCFile(libc_lp);
            }
        }
    }
}
