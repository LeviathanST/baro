const std = @import("std");
const known_folders = @import("known_folders");
const log = std.log.scoped(.zig_compiler);

const utils = @import("utils.zig");
const CliRunner = @import("cli.zig").Runner;

const Allocator = std.mem.Allocator;
const Arg = @import("cli.zig").Arg;

const MAX_INDEX_FILE_SIZE = 1024 * 100; // 100mb
const LAST_MODIFIED_VERSION_FILE = "last_modified_version";

/// Use a `HEAD` request and check `Last-Modified`
/// from http headers then compare content in cache file.
pub fn checkForUpdate(runner: *CliRunner, alloc: Allocator) !void {
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

    const last_modified_file = try std.fmt.allocPrint(
        alloc,
        "{s}/{s}",
        .{ runner.config.options.cache_path.?, LAST_MODIFIED_VERSION_FILE },
    );
    defer alloc.free(last_modified_file);

    // NOTE: init cache if not existed
    std.fs.accessAbsolute(last_modified_file, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            try std.fs.cwd().writeFile(.{
                .data = last_modified.?,
                .sub_path = last_modified_file,
                .flags = .{ .truncate = false },
            });
        },
        else => return err,
    };

    const index_file_path = try std.fmt.allocPrint(
        alloc,
        "{s}/index.json",
        .{runner.config.options.appdata_path.?},
    );
    defer alloc.free(index_file_path);
    // NOTE: fetch a new index file if not existed
    std.fs.accessAbsolute(index_file_path, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            try fetchVerIndex(runner, alloc);
        },
        else => return err,
    };

    const file = try std.fs.openFileAbsolute(last_modified_file, .{ .mode = .read_only });
    const content = try file.readToEndAlloc(alloc, MAX_INDEX_FILE_SIZE);
    defer alloc.free(content);
    if (!std.mem.eql(u8, content, last_modified.?)) {
        log.warn("Detect new versions, use `baro update` command to update.", .{});
    }
}

/// Fetch new index verion and write new last modified version
pub fn update(runner: *CliRunner, alloc: std.mem.Allocator, arg: Arg) !void {
    _ = arg;
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
    try fetchVerIndex(runner, alloc);

    const last_modified_file = try std.fmt.allocPrint(
        alloc,
        "{s}/{s}",
        .{ runner.config.options.cache_path.?, LAST_MODIFIED_VERSION_FILE },
    );
    defer alloc.free(last_modified_file);

    try std.fs.cwd().writeFile(.{
        .data = last_modified.?,
        .sub_path = last_modified_file,
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
        .{runner.config.options.appdata_path.?},
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
    if (arg.value == null) {
        runner.error_data.string = "install";
        return error.MissingValue;
    }
    log.info("Check version index...", .{});
    const appdata_path = runner.config.options.appdata_path.?;
    const index_file_path = try std.fmt.allocPrint(
        alloc,
        "{s}/index.json",
        .{appdata_path},
    );
    defer alloc.free(index_file_path);

    // NOTE: Take tarball link, zig version from the index file
    const index_file = try std.fs.openFileAbsolute(index_file_path, .{});
    defer index_file.close();

    const raw = try index_file.readToEndAlloc(alloc, MAX_INDEX_FILE_SIZE);
    defer alloc.free(raw);

    const builtin = @import("builtin");
    const @"arch-os" = try std.fmt.allocPrint(
        alloc,
        "{s}-{s}",
        .{ @tagName(builtin.cpu.arch), @tagName(builtin.os.tag) },
    );

    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, raw, .{});
    defer parsed.deinit();
    const value: std.json.Value = parsed.value;
    const root = value.object.get(arg.value orelse unreachable) orelse unreachable;

    const src = root.object.get(@"arch-os") orelse {
        runner.error_data.allocated_string = @"arch-os";
        return error.Unsupported;
    };
    defer alloc.free(@"arch-os"); // NOTE: defer here to make sure `arch-os` is supported.

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

pub fn listAllInstalledVersions(
    runner: *CliRunner,
    alloc: Allocator,
    arg: Arg,
) !void {
    _ = arg;
    const appdata_path = runner.config.options.appdata_path.?;
    const appdata_dir = try std.fs.openDirAbsolute(appdata_path, .{ .iterate = true });
    var dir_iter = appdata_dir.iterate();

    var list = std.ArrayList([]const u8).init(alloc);
    defer list.deinit();

    while (try dir_iter.next()) |item| {
        if (item.kind == .directory and std.mem.startsWith(u8, item.name, "zig-")) {
            var split = std.mem.splitScalar(u8, item.name, '-');
            _ = split.first(); // skip `zig-`
            _ = split.next().?; //
            _ = split.next().?; // skip `-arch-os`
            try list.append(split.rest());
        }
    }

    log.info("\r\nAll installed versions:", .{});
    for (list.items[0..]) |it| {
        std.debug.print("- {s}\r\n", .{it});
    }
}

pub fn listAllAvailableVersions(
    runner: *CliRunner,
    alloc: Allocator,
    arg: Arg,
) !void {
    _ = arg;
    const appdata_path = runner.config.options.appdata_path.?;
    const index_file_path = try std.fmt.allocPrint(
        alloc,
        "{s}/index.json",
        .{appdata_path},
    );
    defer alloc.free(index_file_path);

    const index_file = try std.fs.openFileAbsolute(index_file_path, .{});
    const raw = try index_file.readToEndAlloc(alloc, MAX_INDEX_FILE_SIZE);
    defer alloc.free(raw);
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, raw, .{});
    defer parsed.deinit();

    const keys = parsed.value.object.keys();

    log.info("\r\nAll available versions:", .{});
    for (keys) |k| {
        if (std.mem.eql(u8, k, "master")) {
            const master = parsed.value.object.get(k).?;
            std.debug.print("- {s} (master)\r\n", .{master.object.get("version").?.string});
        } else {
            std.debug.print("- {s}\r\n", .{k});
        }
    }
}

// pub fn use(
//     runner: *CliRunner,
//     alloc: Allocator,
//     arg: Arg,
// ) void {}
