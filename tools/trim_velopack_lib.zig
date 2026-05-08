//! Strip Rust `compiler_builtins` members out of Velopack's MSVC `.lib`
//! archives so they don't clash with Zig's own `compiler_rt` at link time.
//! Run from build.zig via the host tool created by linkVelopack().
//!
//! Usage:  trim-velopack-lib <zig-exe> <library.lib>
//!
//! Uses `zig ar` (LLVM's archiver, bundled with the Zig toolchain) so no
//! separate LLVM install is required.
//!
//! Pinned to Zig 0.15.2 std APIs.
const std = @import("std");

pub fn main() !void {
    var gpa_state: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    var args = try std.process.argsWithAllocator(gpa);
    defer args.deinit();

    _ = args.next(); // skip exe name
    const zig_exe = args.next() orelse return usage();
    const lib_path = args.next() orelse return usage();
    if (args.next() != null) return usage();

    // List archive members via `zig ar t`.
    const list_argv = [_][]const u8{ zig_exe, "ar", "t", lib_path };
    const listed = try std.process.Child.run(.{
        .allocator = gpa,
        .argv = &list_argv,
        .max_output_bytes = 32 * 1024 * 1024,
    });
    defer {
        gpa.free(listed.stdout);
        gpa.free(listed.stderr);
    }
    switch (listed.term) {
        .Exited => |c| if (c != 0) {
            std.debug.print("trim-velopack-lib: `zig ar t` failed (code {d})\nstderr: {s}\n", .{ c, listed.stderr });
            return error.ListFailed;
        },
        else => return error.ListFailed,
    }

    // Delete the first matching `compiler_builtins-*` member. Velopack's
    // archives only contain one such member; we mirror the original tool's
    // behaviour of returning after the first delete.
    var lines = std.mem.tokenizeAny(u8, listed.stdout, "\r\n");
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "compiler_builtins-")) continue;
        const del_argv = [_][]const u8{ zig_exe, "ar", "--format=coff", "d", lib_path, line };
        const del = try std.process.Child.run(.{
            .allocator = gpa,
            .argv = &del_argv,
            .max_output_bytes = 1024 * 1024,
        });
        defer {
            gpa.free(del.stdout);
            gpa.free(del.stderr);
        }
        switch (del.term) {
            .Exited => |c| if (c != 0) {
                std.debug.print("trim-velopack-lib: `zig ar d {s}` failed (code {d})\nstderr: {s}\n", .{ line, c, del.stderr });
                return error.DeleteFailed;
            },
            else => return error.DeleteFailed,
        }
        return;
    }
}

fn usage() error{Usage} {
    std.debug.print("usage: trim-velopack-lib <zig-exe> <library.lib>\n", .{});
    return error.Usage;
}
