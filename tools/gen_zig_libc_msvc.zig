//! Emit a Zig `--libc` manifest INI from an msvcup-installed MSVC + Windows
//! SDK tree. Picks the highest-versioned subdirectory under each well-known
//! folder so SDK / MSVC bumps don't require re-pinning.
//!
//! On case-sensitive filesystems it also makes the tree usable at all: the
//! Windows SDK ships `Windows.h` and `kernel32.Lib` but its own headers include
//! `windows.h` and `DriverSpecs.h`, and the linker asks for `kernel32.lib`.
//! Every spelling the headers actually use is symlinked to the real file, the
//! same trick `xwin` uses.
//!
//! Usage:  zig run gen_zig_libc_msvc.zig -- <install-root> <x64|arm64|x86> <out.ini>
//!
//! Pinned to Zig 0.15.2 std APIs.
const std = @import("std");
const builtin = @import("builtin");

/// Case-sensitive filesystems need the alias pass; Windows and macOS don't.
const needs_case_aliases = builtin.os.tag != .windows and builtin.os.tag != .macos;

/// Written into the install root once the header aliases are in place, so the
/// second architecture's run doesn't re-read the whole SDK.
const include_marker = ".zig-case-aliases";

fn die(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print(fmt ++ "\n", args);
    std.process.exit(1);
}

fn pickLatestSubdirName(alloc: std.mem.Allocator, parent: std.fs.Dir) ![]const u8 {
    var best: ?[]const u8 = null;
    var it = parent.iterate();
    while (try it.next()) |e| {
        if (e.kind != .directory) continue;
        const n = e.name;
        if (std.mem.eql(u8, n, ".") or std.mem.eql(u8, n, "..")) continue;
        if (best) |b| {
            if (std.mem.order(u8, n, b) == .gt) {
                alloc.free(b);
                best = try alloc.dupe(u8, n);
            }
        } else {
            best = try alloc.dupe(u8, n);
        }
    }
    return best orelse error.Empty;
}

/// Maps the lowercased form of every real path under a directory to the real
/// one, so a differently-cased spelling can be resolved back to its file.
const CaseMap = struct {
    alloc: std.mem.Allocator,
    entries: std.StringHashMapUnmanaged([]const u8) = .{},

    fn build(alloc: std.mem.Allocator, dir: std.fs.Dir) !CaseMap {
        var self: CaseMap = .{ .alloc = alloc };
        var walker = try dir.walk(alloc);
        defer walker.deinit();
        while (try walker.next()) |entry| {
            // Skip symlinks: aliases from an earlier run, and following them
            // would walk the same subtree twice.
            if (entry.kind == .sym_link) continue;
            const real = try alloc.dupe(u8, entry.path);
            const lower = try std.ascii.allocLowerString(alloc, real);
            const gop = try self.entries.getOrPut(alloc, lower);
            if (!gop.found_existing) gop.value_ptr.* = real;
        }
        return self;
    }

    fn realPath(self: CaseMap, spelling: []const u8) !?[]const u8 {
        const lower = try std.ascii.allocLowerString(self.alloc, spelling);
        defer self.alloc.free(lower);
        return self.entries.get(lower);
    }
};

/// Make `spelling` resolve to `real_rel` under `dir` by symlinking each path
/// component that is spelled differently. Idempotent.
fn aliasSpelling(alloc: std.mem.Allocator, dir: std.fs.Dir, real_rel: []const u8, spelling: []const u8) !void {
    var real_parts = std.mem.tokenizeScalar(u8, real_rel, '/');
    var spell_parts = std.mem.tokenizeScalar(u8, spelling, '/');
    var prefix: []const u8 = "";
    while (real_parts.next()) |real_part| {
        const spell_part = spell_parts.next() orelse return;
        if (!std.mem.eql(u8, real_part, spell_part)) {
            const link = if (prefix.len == 0)
                spell_part
            else
                try std.fs.path.join(alloc, &.{ prefix, spell_part });
            dir.symLink(real_part, link, .{}) catch |err| switch (err) {
                error.PathAlreadyExists => {},
                else => return err,
            };
        }
        prefix = if (prefix.len == 0)
            real_part
        else
            try std.fs.path.join(alloc, &.{ prefix, real_part });
    }
}

fn isHeader(name: []const u8) bool {
    for ([_][]const u8{ ".h", ".H", ".hpp", ".inl", ".idl" }) |ext| {
        if (std.mem.endsWith(u8, name, ext)) return true;
    }
    return false;
}

/// Collect every `#include <…>` / `#include "…"` and `#pragma comment(lib, "…")`
/// spelling appearing in a header.
fn scanReferences(
    alloc: std.mem.Allocator,
    text: []const u8,
    includes: *std.StringHashMapUnmanaged(void),
    libs: *std.StringHashMapUnmanaged(void),
) !void {
    try scanQuoted(alloc, text, "#include", includes);
    try scanQuoted(alloc, text, "comment(lib", libs);
}

fn scanQuoted(
    alloc: std.mem.Allocator,
    text: []const u8,
    marker: []const u8,
    out: *std.StringHashMapUnmanaged(void),
) !void {
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, text, i, marker)) |pos| {
        i = pos + marker.len;
        var j = i;
        while (j < text.len and (text[j] == ' ' or text[j] == '\t' or text[j] == ',')) j += 1;
        if (j >= text.len) break;
        const closer: u8 = switch (text[j]) {
            '<' => '>',
            '"' => '"',
            else => continue,
        };
        const start = j + 1;
        const end = std.mem.indexOfScalarPos(u8, text, start, closer) orelse continue;
        // A quote that never closes on this line isn't an include directive.
        if (std.mem.indexOfScalarPos(u8, text, start, '\n')) |nl| {
            if (nl < end) continue;
        }
        const spelling = text[start..end];
        if (spelling.len == 0 or spelling.len > std.fs.max_path_bytes) continue;
        const gop = try out.getOrPut(alloc, spelling);
        if (!gop.found_existing) gop.key_ptr.* = try alloc.dupe(u8, spelling);
        i = end + 1;
    }
}

/// Read every header under `dir` and gather the spellings it references.
fn scanTree(
    alloc: std.mem.Allocator,
    dir: std.fs.Dir,
    includes: *std.StringHashMapUnmanaged(void),
    libs: *std.StringHashMapUnmanaged(void),
) !void {
    // Header bodies are large and only needed while scanning; keep them off the
    // long-lived arena.
    var scratch = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer scratch.deinit();

    var walker = try dir.walk(alloc);
    defer walker.deinit();
    while (try walker.next()) |entry| {
        if (entry.kind != .file or !isHeader(entry.basename)) continue;
        const text = dir.readFileAlloc(scratch.allocator(), entry.path, 8 << 20) catch continue;
        try scanReferences(alloc, text, includes, libs);
        _ = scratch.reset(.retain_capacity);
    }
}

/// Alias each referenced spelling that doesn't already resolve, relative to one
/// header/library search root.
fn aliasSpellingsIn(
    alloc: std.mem.Allocator,
    dir: std.fs.Dir,
    spellings: std.StringHashMapUnmanaged(void),
) !void {
    const map = try CaseMap.build(alloc, dir);
    var it = spellings.keyIterator();
    while (it.next()) |key| {
        const spelling = key.*;
        if (std.fs.path.isAbsolute(spelling)) continue;
        const normalized = try alloc.dupe(u8, spelling);
        std.mem.replaceScalar(u8, normalized, '\\', '/');
        if (std.mem.indexOf(u8, normalized, "..") != null) continue;
        const real = (try map.realPath(normalized)) orelse continue;
        if (std.mem.eql(u8, real, normalized)) continue;
        try aliasSpelling(alloc, dir, real, normalized);
    }
}

/// Give every mixed-case entry under `dir` an all-lowercase alias — the
/// spelling clang and lld-link reach for by default.
fn aliasLowercaseTree(alloc: std.mem.Allocator, dir: std.fs.Dir) !void {
    const Entry = struct { name: []const u8, is_dir: bool };
    var entries: std.ArrayList(Entry) = .empty;

    var it = dir.iterate();
    while (try it.next()) |e| {
        if (e.kind == .sym_link) continue;
        try entries.append(alloc, .{
            .name = try alloc.dupe(u8, e.name),
            .is_dir = e.kind == .directory,
        });
    }

    for (entries.items) |e| {
        const lower = try std.ascii.allocLowerString(alloc, e.name);
        if (!std.mem.eql(u8, lower, e.name)) {
            dir.symLink(e.name, lower, .{}) catch |err| switch (err) {
                error.PathAlreadyExists => {},
                else => return err,
            };
        }
        if (e.is_dir) {
            var sub = try dir.openDir(e.name, .{ .iterate = true });
            defer sub.close();
            try aliasLowercaseTree(alloc, sub);
        }
    }
}

/// Object files carry `/DEFAULTLIB:` directives in whatever case the producing
/// compiler used — MSVC emits `LIBCMT`, Rust emits `libcmt` — and those names
/// never appear in a header, so the `#pragma comment(lib)` scan can't see them.
/// Alias the spellings a linker directive can plausibly hold.
fn aliasLibCaseVariants(alloc: std.mem.Allocator, dir: std.fs.Dir) !void {
    var names: std.ArrayList([]const u8) = .empty;
    var it = dir.iterate();
    while (try it.next()) |e| {
        if (e.kind != .file) continue;
        try names.append(alloc, try alloc.dupe(u8, e.name));
    }

    for (names.items) |name| {
        const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse continue;
        const stem = name[0..dot];
        const ext = name[dot..];
        const upper_stem = try std.ascii.allocUpperString(alloc, stem);
        const lower_ext = try std.ascii.allocLowerString(alloc, ext);
        const variants = [_][]const u8{
            try std.ascii.allocLowerString(alloc, name),
            try std.mem.concat(alloc, u8, &.{ upper_stem, lower_ext }),
            try std.ascii.allocUpperString(alloc, name),
        };
        for (variants) |variant| {
            if (std.mem.eql(u8, variant, name)) continue;
            dir.symLink(name, variant, .{}) catch |err| switch (err) {
                error.PathAlreadyExists => {},
                else => return err,
            };
        }
    }
}

/// Apply `f` to every immediate subdirectory of `parent`.
fn forEachSubdir(
    alloc: std.mem.Allocator,
    parent: std.fs.Dir,
    f: *const fn (std.mem.Allocator, std.fs.Dir) anyerror!void,
) !void {
    var it = parent.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .directory) continue;
        var dir = openIter(parent, entry.name) orelse continue;
        defer dir.close();
        try f(alloc, dir);
    }
}

fn openIter(root: std.fs.Dir, sub_path: []const u8) ?std.fs.Dir {
    return root.openDir(sub_path, .{ .iterate = true }) catch null;
}

/// Apply `spellings` to every immediate subdirectory of `parent` — the SDK's
/// library roots are one `<flavour>/<arch>` level deep.
fn aliasSpellingsInArchDirs(
    alloc: std.mem.Allocator,
    parent: std.fs.Dir,
    spellings: std.StringHashMapUnmanaged(void),
) !void {
    var it = parent.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .directory) continue;
        var dir = openIter(parent, entry.name) orelse continue;
        defer dir.close();
        try aliasSpellingsIn(alloc, dir, spellings);
    }
}

fn exists(dir: std.fs.Dir, sub_path: []const u8) bool {
    dir.access(sub_path, .{}) catch return false;
    return true;
}

/// Make the SDK usable on a case-sensitive filesystem: lowercase aliases
/// everywhere, plus an alias for every spelling the headers themselves use.
/// Include and library spellings resolve against search roots, not against the
/// version directory, so they are applied per root.
fn normalizeCase(
    alloc: std.mem.Allocator,
    root: std.fs.Dir,
    sdk_inc_ver: []const u8,
    sdk_lib_ver: []const u8,
    msvc_ver: []const u8,
) !void {
    const sdk_include = try std.fs.path.join(alloc, &.{ "Windows Kits/10/Include", sdk_inc_ver });
    const sdk_lib = try std.fs.path.join(alloc, &.{ "Windows Kits/10/Lib", sdk_lib_ver });
    const msvc_include = try std.fs.path.join(alloc, &.{ "VC/Tools/MSVC", msvc_ver, "include" });
    const msvc_lib = try std.fs.path.join(alloc, &.{ "VC/Tools/MSVC", msvc_ver, "lib" });

    for ([_][]const u8{ sdk_include, sdk_lib, msvc_include, msvc_lib }) |sub| {
        var dir = openIter(root, sub) orelse continue;
        defer dir.close();
        try aliasLowercaseTree(alloc, dir);
    }

    var includes: std.StringHashMapUnmanaged(void) = .{};
    var libs: std.StringHashMapUnmanaged(void) = .{};
    for ([_][]const u8{ sdk_include, msvc_include }) |sub| {
        var dir = openIter(root, sub) orelse continue;
        defer dir.close();
        try scanTree(alloc, dir, &includes, &libs);
    }

    // `#include` spellings resolve against each header search root.
    for ([_][]const u8{ "ucrt", "um", "shared", "winrt", "cppwinrt" }) |flavour| {
        const sub = try std.fs.path.join(alloc, &.{ sdk_include, flavour });
        var dir = openIter(root, sub) orelse continue;
        defer dir.close();
        try aliasSpellingsIn(alloc, dir, includes);
    }
    {
        var dir = openIter(root, msvc_include);
        if (dir) |*d| {
            defer d.close();
            try aliasSpellingsIn(alloc, d.*, includes);
        }
    }

    // `#pragma comment(lib, "…")` spellings resolve against each library dir,
    // which sit one `<flavour>/<arch>` level below the SDK lib root.
    for ([_][]const u8{ "ucrt", "um" }) |flavour| {
        const sub = try std.fs.path.join(alloc, &.{ sdk_lib, flavour });
        var dir = openIter(root, sub) orelse continue;
        defer dir.close();
        try aliasSpellingsInArchDirs(alloc, dir, libs);
        try forEachSubdir(alloc, dir, aliasLibCaseVariants);
    }
    {
        var dir = openIter(root, msvc_lib);
        if (dir) |*d| {
            defer d.close();
            try aliasSpellingsInArchDirs(alloc, d.*, libs);
            try forEachSubdir(alloc, d.*, aliasLibCaseVariants);
        }
    }
}

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var args = try std.process.argsWithAllocator(alloc);
    defer args.deinit();
    _ = args.next(); // exe
    const install_root = args.next() orelse die("usage: gen_zig_libc_msvc <install-root> <x64|arm64|x86> <out.ini>", .{});
    const arch = args.next() orelse die("usage: gen_zig_libc_msvc <install-root> <x64|arm64|x86> <out.ini>", .{});
    const out_path = args.next() orelse die("usage: gen_zig_libc_msvc <install-root> <x64|arm64|x86> <out.ini>", .{});

    var root = try std.fs.openDirAbsolute(install_root, .{});
    defer root.close();

    var inc_dir = try root.openDir("Windows Kits/10/Include", .{ .iterate = true });
    defer inc_dir.close();
    const sdk_inc_ver = try pickLatestSubdirName(alloc, inc_dir);

    var lib_dir = try root.openDir("Windows Kits/10/Lib", .{ .iterate = true });
    defer lib_dir.close();
    const sdk_lib_ver = try pickLatestSubdirName(alloc, lib_dir);

    var msvc_root = try root.openDir("VC/Tools/MSVC", .{ .iterate = true });
    defer msvc_root.close();
    const msvc_ver = try pickLatestSubdirName(alloc, msvc_root);

    if (needs_case_aliases and !exists(root, include_marker)) {
        std.debug.print("Normalizing SDK filename case (once per install)...\n", .{});
        try normalizeCase(alloc, root, sdk_inc_ver, sdk_lib_ver, msvc_ver);
        (try root.createFile(include_marker, .{})).close();
    }

    const include_dir = try std.fs.path.join(alloc, &.{ install_root, "Windows Kits/10/Include", sdk_inc_ver, "ucrt" });
    const sys_include_dir = try std.fs.path.join(alloc, &.{ install_root, "VC/Tools/MSVC", msvc_ver, "include" });
    const crt_dir = try std.fs.path.join(alloc, &.{ install_root, "Windows Kits/10/Lib", sdk_lib_ver, "ucrt", arch });
    const msvc_lib_dir = try std.fs.path.join(alloc, &.{ install_root, "VC/Tools/MSVC", msvc_ver, "lib", arch });
    const kernel32_lib_dir = try std.fs.path.join(alloc, &.{ install_root, "Windows Kits/10/Lib", sdk_lib_ver, "um", arch });

    inline for (.{
        .{ include_dir, "stdlib.h" },
        .{ sys_include_dir, "vcruntime.h" },
        .{ crt_dir, "ucrt.lib" },
        .{ msvc_lib_dir, "vcruntime.lib" },
        .{ kernel32_lib_dir, "kernel32.lib" },
    }) |pair| {
        const dir_path = pair.@"0";
        const base = pair.@"1";
        const full = try std.fs.path.join(alloc, &.{ dir_path, base });
        std.fs.accessAbsolute(full, .{}) catch |e| die("missing {s}: {}", .{ full, e });
    }

    if (std.fs.path.dirname(out_path)) |dir| {
        try std.fs.cwd().makePath(dir);
    }
    const out_file = try std.fs.createFileAbsolute(out_path, .{});
    defer out_file.close();

    const contents = try std.fmt.allocPrint(alloc,
        \\include_dir={s}
        \\sys_include_dir={s}
        \\crt_dir={s}
        \\msvc_lib_dir={s}
        \\kernel32_lib_dir={s}
        \\gcc_dir=
        \\
    , .{
        include_dir,
        sys_include_dir,
        crt_dir,
        msvc_lib_dir,
        kernel32_lib_dir,
    });
    try out_file.writeAll(contents);
}
