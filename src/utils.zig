const std = @import("std");

/// This function use `tar` to extract a tarball
pub fn extractTarFile(
    alloc: std.mem.Allocator,
    log: anytype,
    file_path: []const u8,
    output_path: []const u8,
) !void {
    log.info("Extracting...", .{});
    var child: std.process.Child = .init(
        &.{ "tar", "-xf", file_path, "--strip-component", "1", "-C", output_path },
        alloc,
    );
    // TODO: notify exit signal
    _ = try child.spawnAndWait();
    _ = try child.kill();
}

/// This function init `path` (a file or dir) if it not exists.
pub fn initFsIfNotExists(kind: enum { file, dir }, path: []const u8) !void {
    std.fs.accessAbsolute(path, .{ .mode = .read_only }) catch |err| switch (err) {
        error.FileNotFound => {
            switch (kind) {
                .file => _ = try std.fs.createFileAbsolute(path, .{}),
                .dir => try std.fs.makeDirAbsolute(path),
            }
        },
        else => return err,
    };
}
