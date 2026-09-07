//! velopack-zig — Velopack packaging glue for Zig projects.
//!
//! Two calls cover the whole flow from a consumer's build.zig:
//!
//!   const velopack = @import("velopack_zig");
//!
//!   // 1. Link the Velopack runtime into your app. On *-windows-msvc this
//!   //    also installs and wires up MSVC + the Windows SDK when needed.
//!   velopack.linkVelopack(b, exe, .{ .target = target, .optimize = optimize });
//!
//!   // 2. Run `vpk pack` over a staged directory and install its output.
//!   const packaged = velopack.addVelopackedAppDir(b, .{
//!       .name = "myapp",
//!       .version = "1.0.0",
//!       .target = target,
//!       .source_dir = staging.getDirectory(),
//!       .install_dir = .prefix,
//!       .install_subdir = "desktop",
//!       .install_vpk = b.option(bool, "install-vpk", "Download the vpk CLI") orelse false,
//!   });
//!   b.step("package", "Build the release bundle").dependOn(&packaged.step);
//!
//! The package bundles the Velopack release zip, the `vpk` CLI provisioning and
//! a Zig build of mksquashfs (upstream squashfs-tools + zlib), so consumers do
//! not declare any of those themselves.
//!
//! Targets **Zig 0.15.2** on `main`.

const std = @import("std");
const builtin = @import("builtin");

/// Velopack release whose prebuilt runtime archives this package bundles.
/// Keep in sync with the `velopack` dependency URL in build.zig.zon — the
/// `vpk` CLI and the linked runtime should come from the same release.
pub const velopack_version = "0.0.1589-ga2c5a97";

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

// Per-build cache of the host tools we compile out of tools/.
var trim_velopack_tool: ?*std.Build.Step.Compile = null;
var vpk_setup_tool: ?*std.Build.Step.Compile = null;

// Steps that must not be duplicated when several call sites ask for them.
// Keyed by consumer builder plus whatever else makes them distinct.
var step_cache: std.StringHashMapUnmanaged(*std.Build.Step.Run) = .{};

fn cachedRun(
    b: *std.Build,
    key: []const u8,
    context: anytype,
    create: fn (*std.Build, @TypeOf(context)) *std.Build.Step.Run,
) *std.Build.Step.Run {
    const full_key = b.fmt("{x}:{s}", .{ @intFromPtr(b), key });
    const gop = step_cache.getOrPut(b.allocator, full_key) catch @panic("OOM");
    if (!gop.found_existing) gop.value_ptr.* = create(b, context);
    return gop.value_ptr.*;
}

fn hostTool(own: *std.Build, cache: *?*std.Build.Step.Compile, name: []const u8, src: []const u8) *std.Build.Step.Compile {
    if (cache.*) |t| return t;
    const t = own.addExecutable(.{
        .name = name,
        .root_module = own.createModule(.{
            .root_source_file = own.path(src),
            .target = own.graph.host,
            .optimize = .Debug,
        }),
    });
    cache.* = t;
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
    /// Take care of MSVC + the Windows SDK for `*-windows-msvc` targets:
    /// resolve a Zig `--libc` manifest, install the toolchain when there isn't
    /// one, and apply the manifest to `compile` and every `*-windows-msvc`
    /// compile it links (SDL, FreeType, … need the same UCRT headers).
    ///
    /// No effect on other targets. Set to false to do all of that yourself
    /// with `resolveWindowsMsvcLibc` / `addMsvcupSetupStep` /
    /// `applyWindowsMsvcLibcRecursive`.
    handle_libc: bool = true,
    /// Zig `--libc` manifest to use for `*-windows-msvc`, overriding both the
    /// command line `--libc` and the managed toolchain. Only read when
    /// `handle_libc` is set.
    windows_msvc_libc: ?[]const u8 = null,
    /// Directory, relative to the consumer's build root, holding the managed
    /// MSVC + Windows SDK tree and its generated `zig-libc-*.ini`.
    msvc_dir: []const u8 = ".velopack-msvc",
};

pub fn linkVelopack(
    b: *std.Build,
    compile: *std.Build.Step.Compile,
    opts: LinkVelopackOptions,
) void {
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
        const trim = b.addRunArtifact(hostTool(own, &trim_velopack_tool, "trim-velopack-lib", "tools/trim_velopack_lib.zig"));
        trim.addArg(b.graph.zig_exe);
        trim.addFileArg(lib_copy);
        trim.step.dependOn(&wf.step);
        compile.root_module.addObjectFile(lib_copy);
        compile.step.dependOn(&trim.step);
    } else {
        compile.root_module.addObjectFile(lib_src);
    }

    if (target.result.os.tag == .windows) {
        // Velopack's Rust core (ureq, getrandom, TLS) needs Winsock, BCrypt and
        // advapi32's SystemFunction036 (RtlGenRandom).
        compile.root_module.linkSystemLibrary("ws2_32", .{});
        compile.root_module.linkSystemLibrary("bcrypt", .{});
        compile.root_module.linkSystemLibrary("advapi32", .{});
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

    if (opts.handle_libc) handleWindowsMsvcLibc(b, compile, opts);
}

/// Resolve a `--libc` manifest for `*-windows-msvc`, installing MSVC + the
/// Windows SDK when the host has nothing usable, and apply it to every
/// `*-windows-msvc` compile reachable from `compile`.
///
/// Resolution order:
///   1. `opts.windows_msvc_libc`
///   2. the build's own `--libc` (which we then scope to the msvc compiles
///      instead of leaving it on every host-side tool compile too)
///   3. `<build_root>/<msvc_dir>/zig-libc-{x64,arm64}.ini` if it exists
///   4. nothing on a Windows host — Zig auto-detects an installed Visual Studio
///   5. otherwise install the toolchain first (`addMsvcupSetupStep`)
fn handleWindowsMsvcLibc(b: *std.Build, compile: *std.Build.Step.Compile, opts: LinkVelopackOptions) void {
    const target = opts.target;
    if (target.result.os.tag != .windows or target.result.abi != .msvc) return;

    var needs_setup = false;
    const ini: []const u8 = blk: {
        if (opts.windows_msvc_libc orelse b.libc_file) |p| {
            break :blk if (std.fs.path.isAbsolute(p)) b.dupePath(p) else b.pathFromRoot(p);
        }
        const rel = msvcLibcIniPath(b, target, opts.msvc_dir) orelse return;
        if (fileExists(b, rel)) break :blk b.pathFromRoot(rel);
        // A Windows host with Visual Studio installed already has everything
        // Zig needs; don't download a second toolchain behind the user's back.
        if (b.graph.host.result.os.tag == .windows) return;
        needs_setup = true;
        break :blk b.pathFromRoot(rel);
    };

    if (needs_setup) compile.step.dependOn(&addMsvcupSetupStep(b, opts.msvc_dir).step);

    // `b.libc_file` is inherited by *every* compile, host-side build tools
    // included, which breaks them. Scope the manifest to the msvc compiles.
    b.libc_file = null;
    applyWindowsMsvcLibcRecursive(b, &.{compile}, .{ .cwd_relative = ini });
}

fn msvcLibcIniPath(b: *std.Build, target: std.Build.ResolvedTarget, msvc_dir: []const u8) ?[]const u8 {
    const arch_suffix: []const u8 = switch (target.result.cpu.arch) {
        .x86_64 => "x64",
        .aarch64 => "arm64",
        else => return null,
    };
    return b.fmt("{s}/zig-libc-{s}.ini", .{ msvc_dir, arch_suffix });
}

fn fileExists(b: *std.Build, rel: []const u8) bool {
    b.build_root.handle.access(rel, .{}) catch return false;
    return true;
}

// ---------------------------------------------------------------------------
// addVelopackStep / addVelopackedAppDir — run `vpk pack` over a staged app
// directory. velopack-zig owns the whole invocation: provisioning the `vpk`
// CLI, the `[win]`/`[osx]`/`[linux]` selector for cross-OS packaging, and
// mksquashfs for Linux AppImages.
// ---------------------------------------------------------------------------

/// Which `vpk` release to install. The CLI stamps its own Update binaries into
/// the bundle, so it should match the runtime `linkVelopack` links.
pub const VpkVersion = union(enum) {
    /// The release this package bundles (`velopack_version`). Default.
    bundled,
    /// Newest stable release on NuGet, resolved at install time.
    latest,
    /// An explicit NuGet version, e.g. `"1.2.0"`.
    pinned: []const u8,

    fn string(self: VpkVersion) ?[]const u8 {
        return switch (self) {
            .bundled => velopack_version,
            .latest => null,
            .pinned => |v| v,
        };
    }
};

/// A `vpk` argument whose value is a path produced by the build graph.
pub const VpkPathArg = struct {
    /// Flag emitted before the path, e.g. `"--releaseNotes"`. Null passes the
    /// path on its own.
    prefix: ?[]const u8 = null,
    path: std.Build.LazyPath,
};

pub const VelopackOptions = struct {
    /// `--packId`: the app's unique Velopack id.
    name: []const u8,
    /// `--packVersion`: the release version, e.g. `"1.0.0"`.
    version: []const u8,
    /// `--packDir`: directory whose contents become the app payload. Everything
    /// in it is shipped, so stage it (`b.addWriteFiles()`) rather than pointing
    /// at a directory of build leftovers.
    source_dir: std.Build.LazyPath,
    /// Target the payload was built for. Decides the `vpk` platform selector
    /// when packaging across operating systems, the default `--mainExe`
    /// extension, and whether mksquashfs is needed.
    target: std.Build.ResolvedTarget,
    /// `--mainExe`: the executable inside `source_dir` that Velopack launches.
    /// Defaults to `name`, plus `.exe` on Windows.
    main_exe: ?[]const u8 = null,
    /// `--packTitle`: human readable app name.
    title: ?[]const u8 = null,
    /// `--packAuthors`.
    authors: ?[]const u8 = null,
    /// `--icon`.
    icon: ?std.Build.LazyPath = null,
    /// `--channel`.
    channel: ?[]const u8 = null,
    /// `--delta`: `"None"`, `"BestSpeed"` or `"BestSize"`.
    delta: []const u8 = "None",
    /// Appended verbatim after every generated argument, for the many `vpk pack`
    /// flags this wrapper doesn't model — signing identities, notarization
    /// profiles, `--exclude`, `--shortcuts`, and so on. See
    /// https://docs.velopack.io/reference/cli for the full set.
    extra_vpk_args: []const []const u8 = &.{},
    /// Like `extra_vpk_args`, but each value is resolved to a build-graph path
    /// when the step runs, and the pack step waits on whatever produces it.
    /// Use it for flags that take a file this build generates, e.g.
    /// `&.{ .{ .prefix = "--releaseNotes", .path = notes } }`.
    extra_vpk_path_args: []const VpkPathArg = &.{},
    /// Steps that must finish before `vpk pack` runs. `source_dir` already
    /// pulls in whatever produced it; this is for work that touches the staged
    /// payload without being its producer, such as stripping the binary.
    depends_on: []const *std.Build.Step = &.{},

    /// Gate on downloading the `vpk` CLI. Wire it to a build option (see the
    /// README) so a plain `zig build` never reaches out to NuGet; when it is
    /// false and `vpk_dir` has no matching `vpk`, packaging fails with
    /// instructions instead.
    install_vpk: bool = false,
    /// Which `vpk` release the managed install should provide.
    vpk_version: VpkVersion = .bundled,
    /// Directory, relative to the consumer's build root, holding the managed
    /// `vpk` install.
    vpk_dir: []const u8 = ".velopack-tools",
    /// Run this instead of the managed `vpk`, e.g. `&.{ "dotnet", "vpk" }` for
    /// a repo-local `.config/dotnet-tools.json` (pair it with
    /// `addDotnetToolRestoreStep`). Disables `install_vpk` entirely.
    vpk_argv: ?[]const []const u8 = null,
};

pub const VelopackedAppDirOptions = struct {
    name: []const u8,
    version: []const u8,
    source_dir: std.Build.LazyPath,
    target: std.Build.ResolvedTarget,
    main_exe: ?[]const u8 = null,
    title: ?[]const u8 = null,
    authors: ?[]const u8 = null,
    icon: ?std.Build.LazyPath = null,
    channel: ?[]const u8 = null,
    delta: []const u8 = "None",
    extra_vpk_args: []const []const u8 = &.{},
    extra_vpk_path_args: []const VpkPathArg = &.{},
    depends_on: []const *std.Build.Step = &.{},
    install_vpk: bool = false,
    vpk_version: VpkVersion = .bundled,
    vpk_dir: []const u8 = ".velopack-tools",
    vpk_argv: ?[]const []const u8 = null,

    /// Where the release artifacts land, as in `b.addInstallDirectory`.
    install_dir: std.Build.InstallDir = .prefix,
    install_subdir: []const u8 = "",
};

/// Package `source_dir` with `vpk pack` and install the resulting release
/// directory (setup executables, `.nupkg`, `RELEASES` feed, …) under
/// `install_dir` / `install_subdir`, like `b.addInstallDirectory`.
///
/// This is the call most consumers want; make it a dependency of your own
/// `package` step.
pub fn addVelopackedAppDir(
    b: *std.Build,
    opts: VelopackedAppDirOptions,
) *std.Build.Step.InstallDir {
    var pack_opts: VelopackOptions = undefined;
    inline for (@typeInfo(VelopackOptions).@"struct".fields) |field| {
        @field(pack_opts, field.name) = @field(opts, field.name);
    }

    const run = addVelopackStep(b, pack_opts);
    const install = b.addInstallDirectory(.{
        .source_dir = outputDir(run),
        .install_dir = opts.install_dir,
        .install_subdir = opts.install_subdir,
    });
    // Default would be "install generated/", which says nothing in a summary.
    install.step.name = b.fmt("install {s} velopack release", .{opts.name});
    return install;
}

/// Lower-level `vpk pack` Run, for consumers who need to do something with the
/// release directory other than install it. Pair it with `outputDir`.
///
/// Prefer `addVelopackedAppDir`: it is this plus the install step, and one call
/// less to keep in sync with the options above.
pub fn addVelopackStep(b: *std.Build, opts: VelopackOptions) *std.Build.Step.Run {
    const target = opts.target;
    const windows = target.result.os.tag == .windows;

    const run = if (opts.vpk_argv) |argv| b.addSystemCommand(argv) else blk: {
        const setup = cachedVpkSetup(b, opts);
        const r = b.addSystemCommand(&.{vpkExePath(b, opts.vpk_dir)});
        r.step.dependOn(&setup.step);
        break :blk r;
    };

    // `vpk` infers the platform from the host, so packaging for another OS
    // needs an explicit selector.
    if (target.result.os.tag != b.graph.host.result.os.tag) {
        run.addArg(switch (target.result.os.tag) {
            .windows => "[win]",
            .linux => "[linux]",
            .macos => "[osx]",
            else => @panic("velopack-zig: unsupported package OS"),
        });
    }

    run.addArgs(&.{ "pack", "--packId", opts.name, "--packVersion", opts.version });
    run.addArgs(&.{ "--mainExe", opts.main_exe orelse if (windows) b.fmt("{s}.exe", .{opts.name}) else opts.name });
    run.addArgs(&.{ "--delta", opts.delta, "--yes" });
    if (opts.title) |t| run.addArgs(&.{ "--packTitle", t });
    if (opts.authors) |a| run.addArgs(&.{ "--packAuthors", a });
    if (opts.channel) |c| run.addArgs(&.{ "--channel", c });
    if (opts.icon) |icon| {
        run.addArg("--icon");
        run.addFileArg(icon);
    }
    run.addArg("--packDir");
    run.addDirectoryArg(opts.source_dir);
    run.addArg("--outputDir");
    _ = run.addOutputDirectoryArg(b.fmt("{s}-velopack", .{opts.name}));
    run.addArgs(opts.extra_vpk_args);
    for (opts.extra_vpk_path_args) |arg| {
        if (arg.prefix) |prefix| run.addArg(prefix);
        run.addFileArg(arg.path);
    }
    for (opts.depends_on) |dep| run.step.dependOn(dep);

    // vpk targets an older .NET runtime than what is typically installed.
    run.setEnvironmentVariable("DOTNET_ROLL_FORWARD", "Major");

    attachMksquashfsToVpkRun(b, run, target);
    return run;
}

/// The `--outputDir` a Run from `addVelopackStep` writes its release artifacts
/// to.
pub fn outputDir(run: *std.Build.Step.Run) std.Build.LazyPath {
    for (run.argv.items) |arg| switch (arg) {
        .output_directory => |out| return .{ .generated = .{ .file = &out.generated_file } },
        else => {},
    };
    @panic("velopack-zig: Run has no output directory; was it made by addVelopackStep?");
}

fn vpkExePath(b: *std.Build, vpk_dir: []const u8) []const u8 {
    const exe = if (b.graph.host.result.os.tag == .windows) "vpk.exe" else "vpk";
    return b.pathFromRoot(b.pathJoin(&.{ vpk_dir, exe }));
}

fn cachedVpkSetup(b: *std.Build, opts: VelopackOptions) *std.Build.Step.Run {
    const Ctx = struct { dir: []const u8, version: VpkVersion, install: bool };
    const key = b.fmt("vpk:{s}:{s}:{}", .{ opts.vpk_dir, opts.vpk_version.string() orelse "latest", opts.install_vpk });
    return cachedRun(b, key, Ctx{ .dir = opts.vpk_dir, .version = opts.vpk_version, .install = opts.install_vpk }, struct {
        fn create(bb: *std.Build, ctx: Ctx) *std.Build.Step.Run {
            const own = ownBuilder(bb);
            const r = bb.addRunArtifact(hostTool(own, &vpk_setup_tool, "vpk-setup", "tools/vpk_setup.zig"));
            r.addArg(bb.pathFromRoot(ctx.dir));
            r.addArg(if (ctx.install) "1" else "0");
            // TODO: when resolving `.latest`, refuse releases younger than five
            // days so a broken vpk publish can't take builds down with it.
            r.addArg(ctx.version.string() orelse "");
            return r;
        }
    }.create);
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
///
/// `addVelopackStep` already calls this; consumers rarely need it directly.
pub fn buildMksquashfs(b: *std.Build) ?MksquashfsBuild {
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
/// `addVelopackStep` already calls this; consumers rarely need it directly.
pub fn attachMksquashfsToVpkRun(
    b: *std.Build,
    run: *std.Build.Step.Run,
    target: std.Build.ResolvedTarget,
) void {
    if (target.result.os.tag != .linux) return;
    const built = buildMksquashfs(b) orelse return;
    run.addPathDir(built.bin_dir);
    run.step.dependOn(built.step);
}

// ---------------------------------------------------------------------------
// Escape hatches. `linkVelopack(.handle_libc = true)` and `addVelopackStep`
// drive all of these; they stay public for consumers doing something the
// options above don't cover.
// ---------------------------------------------------------------------------

/// Install MSVC + the Windows SDK into `<build_root>/<install_dir>` (or
/// `.velopack-msvc` when null) via [msvcup](https://github.com/marler8997/msvcup)
/// and emit Zig `--libc` manifests (`zig-libc-x64.ini`, `zig-libc-arm64.ini`).
///
/// Cached per build root and directory, so exposing it as your own
/// `msvcup-setup` step and letting `linkVelopack` depend on it yields one
/// install, not two.
pub fn addMsvcupSetupStep(b: *std.Build, install_dir: ?[]const u8) *std.Build.Step.Run {
    const dir = install_dir orelse ".velopack-msvc";
    return cachedRun(b, b.fmt("msvcup:{s}", .{dir}), dir, createMsvcupSetupStep);
}

fn createMsvcupSetupStep(b: *std.Build, install_dir: []const u8) *std.Build.Step.Run {
    const own = ownBuilder(b);

    const resolved_install_dir: []const u8 = if (std.fs.path.isAbsolute(install_dir))
        b.dupePath(install_dir)
    else
        b.pathFromRoot(install_dir);

    const env_path = own.path("tools/msvcup.env").getPath3(b, null).toString(b.allocator) catch |e|
        std.debug.panic("velopack-zig: resolve msvcup.env: {}", .{e});
    const gen_path = own.path("tools/gen_zig_libc_msvc.zig").getPath3(b, null).toString(b.allocator) catch |e|
        std.debug.panic("velopack-zig: resolve gen_zig_libc_msvc.zig: {}", .{e});

    const run: *std.Build.Step.Run = switch (builtin.os.tag) {
        .windows => blk: {
            const script_path = own.path("tools/setup-msvc.ps1").getPath3(b, null).toString(b.allocator) catch |e|
                std.debug.panic("velopack-zig: resolve setup-msvc.ps1: {}", .{e});
            break :blk b.addSystemCommand(&.{
                "powershell", "-NoProfile", "-ExecutionPolicy",   "Bypass",
                "-File",      script_path,  resolved_install_dir,
            });
        },
        else => blk: {
            const script_path = own.path("tools/setup-msvc.sh").getPath3(b, null).toString(b.allocator) catch |e|
                std.debug.panic("velopack-zig: resolve setup-msvc.sh: {}", .{e});
            break :blk b.addSystemCommand(&.{ "bash", script_path, resolved_install_dir });
        },
    };
    run.setEnvironmentVariable("VELOPACK_ZIG_ENV_FILE", env_path);
    run.setEnvironmentVariable("VELOPACK_ZIG_GEN_SCRIPT", gen_path);
    run.setEnvironmentVariable("VELOPACK_ZIG_ZIG", b.graph.zig_exe);
    return run;
}

pub const ResolveWindowsMsvcLibcOptions = struct {
    explicit_path: ?[]const u8 = null,
    install_dir_name: []const u8 = ".velopack-msvc",
    fetch_if_missing: bool = false,
};

pub const ResolvedWindowsMsvcLibc = struct {
    libc_path: ?[]const u8,
    needs_setup: bool,
};

/// Locate the `zig-libc-*.ini` for a `*-windows-msvc` target without applying
/// it: an explicit path wins, then an installed `<install_dir_name>` tree, then
/// (when `fetch_if_missing`) the path `addMsvcupSetupStep` would write, flagged
/// `needs_setup`. Null means "nothing configured" — on a Windows host that
/// leaves Zig's Visual Studio auto-detect in play.
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

    const rel = msvcLibcIniPath(b, target, opts.install_dir_name) orelse
        return .{ .libc_path = null, .needs_setup = false };

    if (fileExists(b, rel))
        return .{ .libc_path = b.pathFromRoot(rel), .needs_setup = false };
    if (opts.fetch_if_missing)
        return .{ .libc_path = b.pathFromRoot(rel), .needs_setup = true };
    return .{ .libc_path = null, .needs_setup = false };
}

/// Apply a `--libc` manifest to every `*-windows-msvc` compile reachable from
/// `roots`, so C dependencies see the same UCRT/MSVC headers as the executable.
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

/// `dotnet tool restore` in the consumer's build root, for projects that pin
/// `vpk` in their own `.config/dotnet-tools.json` and pass
/// `.vpk_argv = &.{ "dotnet", "vpk" }` instead of using the managed install.
pub fn addDotnetToolRestoreStep(b: *std.Build) *std.Build.Step.Run {
    return cachedRun(b, "dotnet-tool-restore", {}, struct {
        fn create(bb: *std.Build, _: void) *std.Build.Step.Run {
            const r = bb.addSystemCommand(&.{ "dotnet", "tool", "restore" });
            r.setCwd(bb.path("."));
            return r;
        }
    }.create);
}
