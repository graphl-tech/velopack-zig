//! Ensure the Velopack CLI (`vpk`) is present in a `dotnet tool --tool-path`
//! directory, optionally installing it.
//!
//!   vpk_setup <tool_dir> <install:0|1> [version]
//!
//! With `install` set, a missing or mismatched `vpk` is installed (replacing
//! whatever was there). Without it, a missing or mismatched `vpk` is a hard
//! error — the consumer's build gates network installs behind an explicit
//! option, so an un-gated build never reaches out to NuGet.
//!
//! An empty `version` means "whatever is installed is fine; install the newest
//! stable release if nothing is".

const std = @import("std");

pub fn main() !void {
    var arena_state: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const args = try std.process.argsAlloc(arena);
    if (args.len < 3) fatal("usage: vpk_setup <tool_dir> <install:0|1> [version]", .{});

    const tool_dir = args[1];
    const may_install = std.mem.eql(u8, args[2], "1");
    const wanted: ?[]const u8 = if (args.len > 3 and args[3].len > 0) args[3] else null;

    const installed = try installedVersion(arena, tool_dir);

    if (installed) |have| {
        if (wanted == null or std.mem.eql(u8, have, wanted.?)) return;
        if (!may_install) fatal(
            \\velopack-zig: {s} has vpk {s}, but vpk {s} was requested.
            \\
            \\Enable the vpk install gate to replace it (`.install_vpk = true`;
            \\with the recommended build option that is `zig build -Dinstall-vpk=true`),
            \\or delete {s} and install vpk there yourself.
        , .{ tool_dir, have, wanted.?, tool_dir });
        try run(arena, &.{ "dotnet", "tool", "uninstall", "--tool-path", tool_dir, "vpk" });
    } else if (!may_install) {
        fatal(
            \\velopack-zig: no vpk found under {s}.
            \\
            \\Enable the vpk install gate to download it (`.install_vpk = true`;
            \\with the recommended build option that is `zig build -Dinstall-vpk=true`),
            \\or install it yourself:
            \\
            \\    dotnet tool install --tool-path {s} vpk{s}{s}
        , .{ tool_dir, tool_dir, if (wanted == null) "" else " --version ", wanted orelse "" });
    }

    if (wanted) |v| {
        try run(arena, &.{ "dotnet", "tool", "install", "--tool-path", tool_dir, "vpk", "--version", v });
    } else {
        try run(arena, &.{ "dotnet", "tool", "install", "--tool-path", tool_dir, "vpk" });
    }
}

/// `dotnet tool list --tool-path <dir>` prints a header, a dashed rule, then
/// one `<package id> <version> <commands>` row per tool. A missing directory
/// makes it exit non-zero, which reads as "nothing installed".
fn installedVersion(arena: std.mem.Allocator, tool_dir: []const u8) !?[]const u8 {
    const res = std.process.Child.run(.{
        .allocator = arena,
        .argv = &.{ "dotnet", "tool", "list", "--tool-path", tool_dir },
        .max_output_bytes = 1 << 20,
    }) catch |err| switch (err) {
        error.FileNotFound => fatal(
            \\velopack-zig: `dotnet` not found on PATH.
            \\
            \\Velopack's CLI is a .NET tool; install the .NET SDK from
            \\https://dotnet.microsoft.com/download to package your app.
        , .{}),
        else => return err,
    };
    switch (res.term) {
        .Exited => |code| if (code != 0) return null,
        else => return null,
    }

    var lines = std.mem.splitScalar(u8, res.stdout, '\n');
    while (lines.next()) |line| {
        var fields = std.mem.tokenizeAny(u8, line, " \t\r");
        const id = fields.next() orelse continue;
        if (!std.ascii.eqlIgnoreCase(id, "vpk")) continue;
        return fields.next() orelse continue;
    }
    return null;
}

fn run(arena: std.mem.Allocator, argv: []const []const u8) !void {
    var child: std.process.Child = .init(argv, arena);
    child.stdin_behavior = .Ignore;
    const term = try child.spawnAndWait();
    const cmd = try std.mem.join(arena, " ", argv);
    switch (term) {
        .Exited => |code| if (code != 0) fatal("velopack-zig: `{s}` failed with exit code {d}", .{ cmd, code }),
        else => fatal("velopack-zig: `{s}` terminated abnormally", .{cmd}),
    }
}

fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print(fmt ++ "\n", args);
    std.process.exit(1);
}
