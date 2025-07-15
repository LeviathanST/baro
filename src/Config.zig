const std = @import("std");
const known_folders = @import("known_folders");

const allocPrint = std.fmt.allocPrint;

const Self = @This();

appdata_path: []const u8,
cache_path: []const u8,
_arena: *std.heap.ArenaAllocator,

pub fn init(alloc: std.mem.Allocator) !Self {
    const arena = try alloc.create(std.heap.ArenaAllocator);
    arena.* = std.heap.ArenaAllocator.init(alloc);

    const allocator = arena.allocator();

    // TODO: get zon object
    const appdata_path = try defaultPath(allocator, .data);
    const cache_path = try defaultPath(allocator, .cache);

    try initIfNotExisted(appdata_path);
    try initIfNotExisted(cache_path);

    return .{
        .appdata_path = appdata_path,
        .cache_path = cache_path,
        ._arena = arena,
    };
}
pub fn deinit(self: *Self) void {
    const alloc = self._arena.child_allocator;
    self._arena.deinit();
    alloc.destroy(self._arena);
}

fn initIfNotExisted(path: []const u8) !void {
    std.fs.accessAbsolute(path, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            try std.fs.makeDirAbsolute(path);
        },
        else => return err,
    };
}

fn defaultPath(alloc: std.mem.Allocator, folder: known_folders.KnownFolder) ![]const u8 {
    return allocPrint(
        alloc,
        "{s}/baro",
        .{(try known_folders.getPath(alloc, folder)).?},
    );
}
