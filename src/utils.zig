/// * Required:
///   - tar
const std = @import("std");
const log = std.log.scoped(.utils);

pub fn extractTarFile(
    alloc: std.mem.Allocator,
    file_path: []const u8,
    output_path: []const u8,
) !void {
    log.info("Extracting...", .{});
    var child: std.process.Child = .init(
        &.{ "tar", "-xf", file_path, "-C", output_path },
        alloc,
    );
    // TODO: notify exit signal
    _ = try child.spawnAndWait();
    _ = try child.kill();
}
