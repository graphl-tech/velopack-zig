//! Strip Rust `compiler_builtins` members out of Velopack's MSVC `.lib`
//! archives so they don't clash with Zig's own `compiler_rt` at link time.
//!
//! Usage:  trim-velopack-lib <zig-exe> <library.lib>
//!
//! Uses `zig ar` bundled with the Zig toolchain (no separate LLVM install).

const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const alloc = init.gpa;

    var it = try std.process.Args.iterateAllocator(init.minimal.args, alloc);
    defer it.deinit();
    _ = it.next() orelse return error.Usage;
    const zig_exe = it.next() orelse {
        std.debug.print("usage: trim-velopack-lib <zig-exe> <library.lib>\n", .{});
        return error.Usage;
    };
    const lib_path = it.next() orelse {
        std.debug.print("usage: trim-velopack-lib <zig-exe> <library.lib>\n", .{});
        return error.Usage;
    };
    if (it.next() != null) return error.Usage;

    const list_argv = [_][]const u8{ zig_exe, "ar", "t", lib_path };
    const listed = try std.process.run(alloc, init.io, .{
        .argv = &list_argv,
        .stdout_limit = std.Io.Limit.limited(32 * 1024 * 1024),
        .stderr_limit = std.Io.Limit.limited(1024 * 1024),
    });
    defer {
        alloc.free(listed.stdout);
        alloc.free(listed.stderr);
    }
    switch (listed.term) {
        .exited => |c| if (c != 0) {
            std.debug.print("trim-velopack-lib: `zig ar t` failed (code {d})\nstderr: {s}\n", .{ c, listed.stderr });
            return error.ListFailed;
        },
        else => return error.ListFailed,
    }

    var lines = std.mem.tokenizeAny(u8, listed.stdout, "\r\n");
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "compiler_builtins-")) continue;
        const del_argv = [_][]const u8{ zig_exe, "ar", "--format=coff", "d", lib_path, line };
        const del = try std.process.run(alloc, init.io, .{
            .argv = &del_argv,
            .stdout_limit = std.Io.Limit.limited(1024 * 1024),
            .stderr_limit = std.Io.Limit.limited(1024 * 1024),
        });
        defer {
            alloc.free(del.stdout);
            alloc.free(del.stderr);
        }
        switch (del.term) {
            .exited => |c| if (c != 0) {
                std.debug.print("trim-velopack-lib: `zig ar d {s}` failed (code {d})\nstderr: {s}\n", .{ line, c, del.stderr });
                return error.DeleteFailed;
            },
            else => return error.DeleteFailed,
        }
        return;
    }
}
