const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const small_reader_threads = b.option(u32, "small-reader-threads", "Default small reader threads (Makefile default: 4)") orelse 4;
    const block_reader_threads = b.option(u32, "block-reader-threads", "Default block reader threads (Makefile default: 4)") orelse 4;

    const upstream = b.dependency("squashfs_tools", .{});
    const zlib_dep = b.dependency("zlib", .{
        .target = target,
        .optimize = optimize,
    });

    const max_reader_threads: u32 = 1024;

    // squashfs-tools is primarily Linux-targeted but compiles on macOS as well
    // (verified against upstream's Makefile build on macOS arm64). Windows is
    // unsupported; consumers there don't need mksquashfs.
    const t = target.result;
    if (t.os.tag == .windows) return;

    var common_flags = std.ArrayList([]const u8).initCapacity(b.allocator, 32) catch @panic("OOM");
    common_flags.appendSlice(b.allocator, &.{
        "-D_FILE_OFFSET_BITS=64",
        "-D_LARGEFILE_SOURCE",
        "-D_GNU_SOURCE",
        "-DCOMP_DEFAULT=\"gzip\"",
        "-DGZIP_SUPPORT",
        "-DXATTR_SUPPORT",
        "-DXATTR_OS_SUPPORT",
        "-DXATTR_DEFAULT",
        "-DVERSION=\"4.7.5\"",
        "-DDATE=\"2026/03/01\"",
        "-DYEAR=\"2026\"",
        b.fmt("-DMAX_READER_THREADS={d}", .{max_reader_threads}),
        b.fmt("-DSMALL_READER_THREADS={d}", .{small_reader_threads}),
        b.fmt("-DBLOCK_READER_THREADS={d}", .{block_reader_threads}),
        "-Wall",
        "-Wno-unused-result",
    }) catch @panic("OOM");

    const mksquashfs_sources = [_][]const u8{
        "squashfs-tools/mksquashfs.c",
        "squashfs-tools/read_fs.c",
        "squashfs-tools/action.c",
        "squashfs-tools/swap.c",
        "squashfs-tools/pseudo.c",
        "squashfs-tools/compressor.c",
        "squashfs-tools/sort.c",
        "squashfs-tools/progressbar.c",
        "squashfs-tools/info.c",
        "squashfs-tools/restore.c",
        "squashfs-tools/process_fragments.c",
        "squashfs-tools/caches-queues-lists.c",
        "squashfs-tools/reader.c",
        "squashfs-tools/tar.c",
        "squashfs-tools/date.c",
        "squashfs-tools/memory.c",
        "squashfs-tools/print_pager.c",
        "squashfs-tools/symbolic_mode.c",
        "squashfs-tools/thread.c",
        "squashfs-tools/nprocessors_compat.c",
        "squashfs-tools/limit.c",
        "squashfs-tools/virt_disk_pos.c",
        "squashfs-tools/gzip_wrapper.c",
        "squashfs-tools/xattr.c",
        "squashfs-tools/read_xattrs.c",
        "squashfs-tools/tar_xattr.c",
        "squashfs-tools/pseudo_xattr.c",
        "squashfs-tools/xattr_system.c",
    };

    const unsquashfs_sources = [_][]const u8{
        "squashfs-tools/unsquashfs.c",
        "squashfs-tools/unsquash-1.c",
        "squashfs-tools/unsquash-2.c",
        "squashfs-tools/unsquash-3.c",
        "squashfs-tools/unsquash-4.c",
        "squashfs-tools/unsquash-123.c",
        "squashfs-tools/unsquash-34.c",
        "squashfs-tools/unsquash-1234.c",
        "squashfs-tools/unsquash-12.c",
        "squashfs-tools/swap.c",
        "squashfs-tools/compressor.c",
        "squashfs-tools/unsquashfs_info.c",
        "squashfs-tools/date.c",
        "squashfs-tools/memory.c",
        "squashfs-tools/print_pager.c",
        "squashfs-tools/nprocessors_compat.c",
        "squashfs-tools/limit.c",
        "squashfs-tools/gzip_wrapper.c",
        "squashfs-tools/read_xattrs.c",
        "squashfs-tools/unsquashfs_xattr.c",
        "squashfs-tools/unsquashfs_xattr_system.c",
    };

    const mksquashfs = b.addExecutable(.{
        .name = "mksquashfs",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    mksquashfs.root_module.addCSourceFiles(.{
        .root = upstream.path(""),
        .files = &mksquashfs_sources,
        .flags = common_flags.items,
    });
    {
        var help_flags = common_flags.clone(b.allocator) catch @panic("OOM");
        help_flags.append(b.allocator, "-DCOMPRESSORS=\"gzip (default)\"") catch @panic("OOM");
        mksquashfs.root_module.addCSourceFile(.{
            .file = upstream.path("squashfs-tools/mksquashfs_help.c"),
            .flags = help_flags.items,
        });
    }
    mksquashfs.root_module.addIncludePath(upstream.path("squashfs-tools"));
    mksquashfs.root_module.linkLibrary(zlib_dep.artifact("z"));
    mksquashfs.root_module.linkSystemLibrary("pthread", .{});
    mksquashfs.root_module.linkSystemLibrary("m", .{});
    b.installArtifact(mksquashfs);

    const unsquashfs = b.addExecutable(.{
        .name = "unsquashfs",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    unsquashfs.root_module.addCSourceFiles(.{
        .root = upstream.path(""),
        .files = &unsquashfs_sources,
        .flags = common_flags.items,
    });
    {
        var help_flags = common_flags.clone(b.allocator) catch @panic("OOM");
        help_flags.append(b.allocator, "-DDECOMPRESSORS=\"gzip\"") catch @panic("OOM");
        unsquashfs.root_module.addCSourceFile(.{
            .file = upstream.path("squashfs-tools/unsquashfs_help.c"),
            .flags = help_flags.items,
        });
    }
    unsquashfs.root_module.addIncludePath(upstream.path("squashfs-tools"));
    unsquashfs.root_module.linkLibrary(zlib_dep.artifact("z"));
    unsquashfs.root_module.linkSystemLibrary("pthread", .{});
    unsquashfs.root_module.linkSystemLibrary("m", .{});
    b.installArtifact(unsquashfs);
}
