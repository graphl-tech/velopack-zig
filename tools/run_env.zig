//! Run a command with environment changes applied when it runs, on top of the environment the
//! build is running in. `vpk` needs `DOTNET_ROLL_FORWARD=Major`, and `mksquashfs` on its `PATH`
//! for a Linux AppImage.
//!
//! Why a program: in Zig 0.17, `Run.setEnvironmentVariable` copies the whole environment while
//! the build is configured, and that copy is cached with the configuration, so the command keeps
//! getting the environment the first configure saw (a `DOTNET_ROOT` set later never arrives).
//! `Run.addPathDir` is gone too, and the directory is only known once the build runs.
//!
//! Usage: `run_env [--path <dir>]... [--env <NAME>=<value>]... -- <command> [args...]`.
//! Exits with the command's exit code.
const std = @import("std");
const builtin = @import("builtin");

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);
    const env = init.environ_map;
    const sep = if (builtin.target.os.tag == .windows) ";" else ":";

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--")) break;
        if (i + 1 >= args.len) usage();
        i += 1;
        if (std.mem.eql(u8, arg, "--path")) {
            const dir = try std.fs.path.resolve(arena, &.{args[i]});
            const path = if (env.get("PATH")) |p| try std.fmt.allocPrint(arena, "{s}{s}{s}", .{ dir, sep, p }) else dir;
            try env.put("PATH", path);
        } else if (std.mem.eql(u8, arg, "--env")) {
            const eq = std.mem.indexOfScalar(u8, args[i], '=') orelse usage();
            try env.put(args[i][0..eq], args[i][eq + 1 ..]);
        } else usage();
    }
    if (i + 1 >= args.len) usage();

    var child = try std.process.spawn(io, .{ .argv = args[i + 1 ..], .environ_map = env });
    switch (try child.wait(io)) {
        .exited => |code| std.process.exit(code),
        else => std.process.exit(1),
    }
}

fn usage() noreturn {
    std.debug.print("usage: run_env [--path <dir>]... [--env <NAME>=<value>]... -- <command> [args...]\n", .{});
    std.process.exit(2);
}
