const std = @import("std");
const known_folders = @import("known_folders");
const log = std.log.scoped(.zig_compiler);

const utils = @import("utils.zig");
const CliRunner = @import("cli.zig").Runner;

const Allocator = std.mem.Allocator;
const Arg = @import("cli.zig").Arg;

const MAX_INDEX_FILE_SIZE = 1024 * 100; // 100mb

/// Use a `HEAD` request and check `Last-Modified`
/// from http headers then compare content in cache file.
pub fn checkForUpdateIndex(runner: *CliRunner, alloc: Allocator) !void {
    log.info("Check for version index update...", .{});
    var http_client: std.http.Client = .{ .allocator = alloc };
    defer http_client.deinit();
    var header_buf: [1024]u8 = undefined;
    var req = try http_client.open(
        .HEAD,
        try .parse("https://ziglang.org/download/index.json"),
        .{ .server_header_buffer = &header_buf },
    );
    defer req.deinit();

    try req.send();
    try req.finish();
    try req.wait();

    const res = req.response;
    var headers = res.iterateHeaders();
    var last_modified: ?[]const u8 = null;
    while (headers.next()) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, "last-modified")) {
            last_modified = header.value;
        }
    }
    if (last_modified == null) {
        runner.error_data.string = "last-modified";
        return error.NotFound;
    }

    const baro_cache_file_path = try std.fmt.allocPrint(
        alloc,
        "{s}/{s}",
        .{ runner.config.cache_path, "baro" },
    );
    defer alloc.free(baro_cache_file_path);

    // init cache if not existed
    std.fs.accessAbsolute(baro_cache_file_path, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            try fetchVerIndex(runner, alloc);
            try std.fs.cwd().writeFile(.{
                .data = last_modified.?,
                .sub_path = baro_cache_file_path,
                .flags = .{ .truncate = false },
            });
            return;
        },
        else => return err,
    };

    const file = try std.fs.openFileAbsolute(baro_cache_file_path, .{ .mode = .read_only });
    const content = try file.readToEndAlloc(alloc, MAX_INDEX_FILE_SIZE);
    defer alloc.free(content);
    if (!std.mem.eql(u8, content, last_modified.?)) {
        try fetchVerIndex(runner, alloc);
    }
    try std.fs.cwd().writeFile(.{
        .data = last_modified.?,
        .sub_path = baro_cache_file_path,
        .flags = .{ .truncate = false },
    });
}

pub fn fetchVerIndex(runner: *CliRunner, alloc: Allocator) !void {
    log.info("Fetching new version index...", .{});
    var http_client = std.http.Client{
        .allocator = alloc,
    };
    defer http_client.deinit();
    var response_body = std.ArrayList(u8).init(alloc);
    defer response_body.deinit();

    const fetch_result = try http_client.fetch(.{
        .method = .GET,
        .max_append_size = MAX_INDEX_FILE_SIZE, // 100MB
        .response_storage = .{ .dynamic = &response_body },
        .location = .{ .uri = try .parse("https://ziglang.org/download/index.json") },
    });
    if (fetch_result.status != .ok) {
        runner.error_data.string = "version index of the Zig compiler";
        return error.FetchingFailed;
    }

    const index_file_path = try std.fmt.allocPrint(
        alloc,
        "{s}/index.json",
        .{runner.config.appdata_path},
    );
    defer alloc.free(index_file_path);

    log.info("Index file path: {s}", .{index_file_path});
    try std.fs.cwd().writeFile(.{
        .sub_path = index_file_path,
        .data = response_body.items[0..],
        .flags = .{ .truncate = false },
    });
    log.info("Fetching successfully!", .{});
}

pub fn install(runner: *CliRunner, alloc: Allocator, arg: Arg) !void {
    log.info("Check index version...", .{});
    const appdata_path = runner.config.appdata_path;
    const index_file_path = try std.fmt.allocPrint(
        alloc,
        "{s}/index.json",
        .{appdata_path},
    );
    defer alloc.free(index_file_path);

    std.fs.accessAbsolute(index_file_path, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            try fetchVerIndex(runner, alloc);
        },
        else => return err,
    };
    // NOTE: Take tarball link, zig version from the index file
    const index_file = try std.fs.openFileAbsolute(index_file_path, .{});
    defer index_file.close();

    const raw = try index_file.readToEndAlloc(alloc, MAX_INDEX_FILE_SIZE);
    defer alloc.free(raw);

    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, raw, .{});
    defer parsed.deinit();
    const value: std.json.Value = parsed.value;
    const root = value.object.get(arg.value orelse unreachable) orelse unreachable;
    const src = root.object.get("src") orelse unreachable;
    const tarball_link = (src.object.get("tarball") orelse unreachable).string;

    const version = blk: {
        if (std.mem.eql(u8, "master", arg.value.?)) {
            break :blk (root.object.get("version") orelse unreachable).string;
        } else {
            break :blk arg.value.?;
        }
    };

    // NOTE: Download tarball file
    var http_client: std.http.Client = .{ .allocator = alloc };
    defer http_client.deinit();

    log.info("Download from {s}", .{tarball_link});
    var header_buf: [1024]u8 = undefined;
    var req = try http_client.open(
        .GET,
        try .parse(tarball_link),
        .{ .server_header_buffer = &header_buf },
    );
    defer req.deinit();
    try req.send();

    try req.finish();
    try req.wait();

    const file_path = try std.fmt.allocPrint(
        alloc,
        "{s}/zig-{s}.tar.xz",
        .{ appdata_path, version },
    );
    defer alloc.free(file_path);
    const file = try std.fs.cwd().createFile(file_path, .{});
    defer file.close();

    var buffer: [8192]u8 = undefined;
    var total_bytes: usize = 0;
    while (true) {
        const byte_read = try req.read(&buffer);
        if (byte_read == 0) break;
        try file.writeAll(buffer[0..byte_read]);
        total_bytes += byte_read;
    }
    log.info(
        "Downloaded to {s}",
        .{file_path},
    );
    try utils.extractTarFile(alloc, log, file_path, appdata_path);
}
