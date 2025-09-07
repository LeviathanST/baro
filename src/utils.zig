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
/// return `true` if the new one is created.
pub fn initFsIfNotExists(
    kind: enum { file, dir },
    path: []const u8,
    opts: struct {
        /// This field can be used as a default data
        /// when create a file.
        default_data: []const u8 = "",
    },
) !bool {
    std.fs.accessAbsolute(path, .{ .mode = .read_only }) catch |err| switch (err) {
        error.FileNotFound => {
            switch (kind) {
                .file => {
                    std.log.info("Create file: {s} - default data: {s}", .{ path, opts.default_data });
                    const file = try std.fs.createFileAbsolute(path, .{});
                    defer file.close();
                    try file.writeAll(opts.default_data);
                    return true;
                },
                .dir => try std.fs.makeDirAbsolute(path),
            }
            return true;
        },
        else => return err,
    };
    return false;
}
