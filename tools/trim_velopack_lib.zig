//! Strip Rust `compiler_builtins` members out of Velopack's MSVC `.lib`
//! archives so they don't clash with Zig's own `compiler_rt` at link time.
//! Run from build.zig via the host tool created by linkVelopack().
//!
//! Usage:  trim-velopack-lib <zig-exe> <library.lib>
//!
//! Uses `zig ar` (LLVM's archiver, bundled with the Zig toolchain) so no
//! separate LLVM install is required.
//!
//! Pinned to Zig 0.16.0 std APIs.
const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    var args = try init.minimal.args.iterateAllocator(gpa);
    defer args.deinit();

    _ = args.next(); // skip exe name
    const zig_exe = args.next() orelse return usage();
    const lib_path = args.next() orelse return usage();
    if (args.next() != null) return usage();

    // List archive members via `zig ar t`.
    const list_argv = [_][]const u8{ zig_exe, "ar", "t", lib_path };
    const listed = try std.process.run(gpa, io, .{
        .argv = &list_argv,
        .stdout_limit = .limited(32 * 1024 * 1024),
        .stderr_limit = .limited(32 * 1024 * 1024),
    });
    defer {
        gpa.free(listed.stdout);
        gpa.free(listed.stderr);
    }
    switch (listed.term) {
        .exited => |c| if (c != 0) {
            std.debug.print("trim-velopack-lib: `zig ar t` failed (code {d})\nstderr: {s}\n", .{ c, listed.stderr });
            return error.ListFailed;
        },
        else => return error.ListFailed,
    }

    // Delete every `compiler_builtins-*` member. The x64/x86 archives hold a
    // single one, arm64 holds a couple hundred codegen units.
    var del_argv: std.ArrayList([]const u8) = .empty;
    defer del_argv.deinit(gpa);
    try del_argv.appendSlice(gpa, &.{ zig_exe, "ar", "--format=coff", "d", lib_path });

    var lines = std.mem.tokenizeAny(u8, listed.stdout, "\r\n");
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "compiler_builtins-")) continue;
        try del_argv.append(gpa, line);
    }
    // Nothing to trim.
    if (del_argv.items.len == 5) return;

    const del = try std.process.run(gpa, io, .{
        .argv = del_argv.items,
        .stdout_limit = .limited(1024 * 1024),
        .stderr_limit = .limited(1024 * 1024),
    });
    defer {
        gpa.free(del.stdout);
        gpa.free(del.stderr);
    }
    switch (del.term) {
        .exited => |c| if (c != 0) {
            std.debug.print("trim-velopack-lib: `zig ar d` failed (code {d})\nstderr: {s}\n", .{ c, del.stderr });
            return error.DeleteFailed;
        },
        else => return error.DeleteFailed,
    }
}

fn usage() error{Usage} {
    std.debug.print("usage: trim-velopack-lib <zig-exe> <library.lib>\n", .{});
    return error.Usage;
}
