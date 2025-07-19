const std = @import("std");
const known_folders = @import("known_folders");
const cli = @import("cli.zig");
const allocPrint = std.fmt.allocPrint;
const log = std.log.scoped(.config);

const Self = @This();

options: Options,
_arena: *std.heap.ArenaAllocator,

const Options = struct {
    appdata_path: ?[]const u8,
    cache_path: ?[]const u8,
    check_for_update: ?bool,
    zigc: struct {
        enabled: ?bool,
        check_for_update: ?bool,
    },
    zlint: struct {
        enabled: ?bool,
        check_for_update: ?bool,
    },
    zls: struct {
        enabled: ?bool,
        check_for_update: ?bool,
    },

    pub fn default(alloc: std.mem.Allocator) !Options {
        const appdata_path = try defaultPath(alloc, .data, "");
        const cache_path = try defaultPath(alloc, .cache, "");

        return .{
            .appdata_path = appdata_path,
            .cache_path = cache_path,
            .check_for_update = true,
            .zigc = .{
                .enabled = true,
                .check_for_update = true,
            },
            .zlint = .{
                .enabled = true,
                .check_for_update = true,
            },
            .zls = .{
                .enabled = true,
                .check_for_update = true,
            },
        };
    }

    pub fn deinit(self: *Options, alloc: std.mem.Allocator) void {
        alloc.free(self.appdata_path);
        alloc.free(self.cache_path);
    }
};

pub fn init(alloc: std.mem.Allocator) !Self {
    const arena = try alloc.create(std.heap.ArenaAllocator);
    arena.* = std.heap.ArenaAllocator.init(alloc);
    errdefer {
        arena.deinit();
        alloc.destroy(arena);
    }

    const allocator = arena.allocator();
    // TODO: user-speicifed from file.
    const default_options = try Options.default(allocator);

    try initIfNotExisted(default_options.appdata_path.?);
    try initIfNotExisted(default_options.cache_path.?);

    return .{
        .options = default_options,
        ._arena = arena,
    };
}

pub fn deinit(self: *Self) void {
    const alloc = self._arena.child_allocator;
    self._arena.deinit();
    alloc.destroy(self._arena);
}

pub fn print(runner: *cli.Runner, allocator: std.mem.Allocator, arg: cli.Arg) !void {
    _ = arg;
    _ = runner;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const default_options = try Options.default(alloc);

    const appdata_path = default_options.appdata_path.?;
    const cache_path = default_options.cache_path.?;
    const zigc = default_options.zigc.enabled.?;
    const zlint = default_options.zlint.enabled.?;
    const zls = default_options.zls.enabled.?;

    log.info(
        \\
        \\ Appdata path: {s}
        \\ Cache path: {s}
        \\
        \\ Enabled zigc: {any}
        \\ Enabled zlint: {any}
        \\ Enabled zls: {any}
    , .{
        appdata_path,
        cache_path,
        zigc,
        zlint,
        zls,
    });
}

fn initIfNotExisted(path: []const u8) !void {
    std.fs.accessAbsolute(path, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            try std.fs.makeDirAbsolute(path);
        },
        else => return err,
    };
}

fn defaultPath(alloc: std.mem.Allocator, folder: known_folders.KnownFolder, sub_path: []const u8) ![]const u8 {
    return allocPrint(
        alloc,
        "{s}/baro{s}",
        .{
            (try known_folders.getPath(alloc, folder)).?,
            sub_path,
        },
    );
}
