const std = @import("std");
const c = @cImport({
    @cInclude("Velopack.h");
});

pub fn main() void {
    // Handles Velopack's install/update hooks. A no-op outside an install, so
    // this is also safe to run straight out of zig-out.
    c.vpkc_app_run(null);
    std.debug.print("hello from the velopack-zig sample\n", .{});
}
