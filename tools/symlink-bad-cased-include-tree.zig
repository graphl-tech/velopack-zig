//! Make a case-unaware header / library tree usable on a case-sensitive
//! filesystem, the way [xwin](https://github.com/Jake-Shadle/xwin) does.
//!
//! The Windows SDK ships `Windows.h` and `kernel32.Lib`, its own headers
//! `#include "DriverSpecs.h"` next to a real `driverspecs.h`, and lld-link asks
//! for `kernel32.lib`. NTFS folds all of that onto one file; ext4 resolves only
//! the exact bytes.
//!
//! There is nothing to normalize *toward*: the inconsistency lives in the
//! references, spread across thousands of read-only headers, so renaming files
//! to one canonical case just breaks whoever spelled it the other way. Instead
//! give every real file a sibling symlink for each spelling anything actually
//! uses. That is purely additive — the real name keeps working — so the pass is
//! idempotent and can be re-run over a tree it has already seen.
//!
//! Spellings come from two places:
//!
//!   - **Enumerated.** The tree is a closed set of text files, so every
//!     `#include <…>` / `#include "…"` and `#pragma comment(lib, "…")` in it can
//!     simply be read out. Exhaustive for references between the headers: a
//!     spelling that appears in no header cannot be asked for by one.
//!
//!   - **Guessed.** Some spellings appear in no header at all. clang and
//!     lld-link reach for all-lowercase by default, and `/DEFAULTLIB:`
//!     directives are baked into binary object members in whatever case
//!     produced them (MSVC emits `LIBCMT`, Rust emits `libcmt`). Libraries
//!     therefore also get lowercase, uppercase-stem and all-caps aliases on
//!     spec.
//!
//! That second bucket is convention-matching, not proof — a new vendor's object
//! file can always name a spelling nobody predicted. The complete fix is a
//! case-insensitive *view* of the tree (a FUSE mount, or `mkdir --casefold` on
//! ext4/f2fs), not a symlink farm; this is the portable approximation.
//!
//! Two details make the aliases actually resolve. Links are created in the
//! **real** parent directory one path component at a time, because lookup is
//! per-directory — `GL/GL.h` against a real `gl/gl.h` needs a link at both
//! levels. And `#include` spellings resolve against each **search root**, not
//! against the tree above them, so `DriverSpecs.h` has to be matched inside
//! `shared/` rather than as `shared/driverspecs.h` one level up.
//!
//! Pinned to Zig 0.15.2 std APIs.

const std = @import("std");
const builtin = @import("builtin");

/// Whether this pass is needed at all. Windows and (by default) macOS fold case
/// in the filesystem, so the aliases would be pure noise there.
pub const host_needs_aliases = builtin.os.tag != .windows and builtin.os.tag != .macos;

/// Where the interesting directories live, relative to the tree root. Every
/// path is optional: missing ones are skipped, so one layout can describe
/// several SDK versions.
pub const Layout = struct {
    /// Trees where every mixed-case entry gets an all-lowercase alias,
    /// recursively.
    lowercase_trees: []const []const u8 = &.{},
    /// Trees whose headers are read to collect referenced spellings.
    scan_trees: []const []const u8 = &.{},
    /// Directories that `#include` spellings resolve against.
    include_roots: []const []const u8 = &.{},
    /// Directories whose *immediate subdirectories* are library search roots —
    /// SDK libraries sit one `<flavour>/<arch>` level down.
    lib_root_parents: []const []const u8 = &.{},
};

/// Symlink every spelling the tree uses onto the file that really exists.
/// Allocations live for the whole pass; hand it an arena.
pub fn apply(alloc: std.mem.Allocator, root: std.fs.Dir, layout: Layout) !void {
    for (layout.lowercase_trees) |sub| {
        var dir = openIter(root, sub) orelse continue;
        defer dir.close();
        try aliasLowercaseTree(alloc, dir);
    }

    var includes: std.StringHashMapUnmanaged(void) = .{};
    var libs: std.StringHashMapUnmanaged(void) = .{};
    for (layout.scan_trees) |sub| {
        var dir = openIter(root, sub) orelse continue;
        defer dir.close();
        try scanTree(alloc, dir, &includes, &libs);
    }

    for (layout.include_roots) |sub| {
        var dir = openIter(root, sub) orelse continue;
        defer dir.close();
        try aliasSpellingsIn(alloc, dir, includes);
    }

    for (layout.lib_root_parents) |sub| {
        var parent = openIter(root, sub) orelse continue;
        defer parent.close();
        var it = parent.iterate();
        while (try it.next()) |entry| {
            if (entry.kind != .directory) continue;
            var dir = openIter(parent, entry.name) orelse continue;
            defer dir.close();
            try aliasSpellingsIn(alloc, dir, libs);
            try aliasLibCaseVariants(alloc, dir);
        }
    }
}

fn openIter(root: std.fs.Dir, sub_path: []const u8) ?std.fs.Dir {
    return root.openDir(sub_path, .{ .iterate = true }) catch null;
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

/// Alias each referenced spelling that doesn't already resolve, relative to one
/// header / library search root.
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

/// The guessed half: `/DEFAULTLIB:` directives live in binary object members,
/// so no header scan can see them. Alias the spellings such a directive can
/// plausibly hold.
fn aliasLibCaseVariants(alloc: std.mem.Allocator, dir: std.fs.Dir) !void {
    var names: std.ArrayList([]const u8) = .empty;
    var it = dir.iterate();
    while (try it.next()) |e| {
        if (e.kind != .file) continue;
        try names.append(alloc, try alloc.dupe(u8, e.name));
    }

    for (names.items) |name| {
        const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse continue;
        const upper_stem = try std.ascii.allocUpperString(alloc, name[0..dot]);
        const lower_ext = try std.ascii.allocLowerString(alloc, name[dot..]);
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

fn isHeader(name: []const u8) bool {
    for ([_][]const u8{ ".h", ".H", ".hpp", ".inl", ".idl" }) |ext| {
        if (std.mem.endsWith(u8, name, ext)) return true;
    }
    return false;
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
        try scanQuoted(alloc, text, "#include", includes);
        try scanQuoted(alloc, text, "comment(lib", libs);
        _ = scratch.reset(.retain_capacity);
    }
}

/// Collect what follows `marker` between `<…>` or `"…"`.
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
