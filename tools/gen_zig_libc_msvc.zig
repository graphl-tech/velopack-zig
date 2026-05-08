//! Emit a Zig `--libc` manifest INI from an msvcup-installed MSVC + Windows
//! SDK tree. Picks the highest-versioned subdirectory under each well-known
//! folder so SDK / MSVC bumps don't require re-pinning.
//!
//! Usage:  zig run gen_zig_libc_msvc.zig -- <install-root> <x64|arm64|x86> <out.ini>
const std = @import("std");
const Io = std.Io;
const Dir = std.Io.Dir;

fn die(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print(fmt ++ "\n", args);
    std.process.exit(1);
}

fn pickLatestSubdirName(alloc: std.mem.Allocator, io: Io, parent: Dir) ![]const u8 {
    var best: ?[]const u8 = null;
    var it = parent.iterate();
    while (try it.next(io)) |e| {
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

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var args = try init.minimal.args.iterateAllocator(alloc);
    defer args.deinit();
    _ = args.next(); // exe
    const install_root = args.next() orelse die("usage: gen_zig_libc_msvc <install-root> <x64|arm64|x86> <out.ini>", .{});
    const arch = args.next() orelse die("usage: gen_zig_libc_msvc <install-root> <x64|arm64|x86> <out.ini>", .{});
    const out_path = args.next() orelse die("usage: gen_zig_libc_msvc <install-root> <x64|arm64|x86> <out.ini>", .{});

    var root = try Dir.openDirAbsolute(io, install_root, .{});
    defer root.close(io);

    var inc_dir = try root.openDir(io, "Windows Kits/10/Include", .{ .iterate = true });
    defer inc_dir.close(io);
    const sdk_inc_ver = try pickLatestSubdirName(alloc, io, inc_dir);

    var lib_dir = try root.openDir(io, "Windows Kits/10/Lib", .{ .iterate = true });
    defer lib_dir.close(io);
    const sdk_lib_ver = try pickLatestSubdirName(alloc, io, lib_dir);

    var msvc_root = try root.openDir(io, "VC/Tools/MSVC", .{ .iterate = true });
    defer msvc_root.close(io);
    const msvc_ver = try pickLatestSubdirName(alloc, io, msvc_root);

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
        Dir.accessAbsolute(io, full, .{}) catch |e| die("missing {s}: {}", .{ full, e });
    }

    if (std.fs.path.dirname(out_path)) |dir| {
        try Dir.cwd().createDirPath(io, dir);
    }

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

    try Dir.cwd().writeFile(io, .{
        .sub_path = out_path,
        .data = contents,
    });
}
