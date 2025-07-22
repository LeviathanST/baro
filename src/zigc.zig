const std = @import("std");
const known_folders = @import("known_folders");
const log = std.log.scoped(.zig_compiler);

const tool = @import("tool.zig");
const utils = @import("utils.zig");
const cli = @import("cli.zig");
const Runner = cli.Runner;
const RunnerError = cli.Runner.Error;

const Allocator = std.mem.Allocator;
const Arg = @import("cli.zig").Arg;

const MAX_INDEX_FILE_SIZE = 1024 * 100; // 100mb
const LAST_MODIFIED_VERSION_FILE = "zigc_last_modified_version";
const INDEX_FILE_NAME_WITH_EXT = "zigc_index_file.json";

/// Only notify new master version.
///
/// Use a `HEAD` request and check `Last-Modified`
/// from http headers then compare content in cache file.
///
/// Write new `last-modified` and fetch new `index version`
/// if index version or last-modified file is not existed.
pub fn checkForUpdate(runner: *Runner, alloc: Allocator) !void {
    if (!runner.config.options.check_for_update.?) return;
    if (!runner.config.options.zigc.enabled.?)
        return;
    if (!runner.config.options.zigc.check_for_update.?)
        return;

    log.debug("Check new master version", .{});
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
        runner.error_data = RunnerError{ .string = "last-modified" };
        return error.NotFound;
    }

    const last_modified_file = try std.fmt.allocPrint(
        alloc,
        "{s}/{s}",
        .{ runner.config.options.cache_path.?, LAST_MODIFIED_VERSION_FILE },
    );
    defer alloc.free(last_modified_file);

    std.fs.accessAbsolute(last_modified_file, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            log.debug("Write new last modified", .{});
            try std.fs.cwd().writeFile(.{
                .data = last_modified.?,
                .sub_path = last_modified_file,
                .flags = .{ .truncate = false },
            });
            try fetchVerIndex(runner, alloc);
        },
        else => return err,
    };
    check_for_update_master: {
        {
            const zig_exe = try std.fmt.allocPrint(
                alloc,
                "{s}/bin/zig",
                .{runner.config.options.appdata_path.?},
            );
            defer alloc.free(zig_exe);
            if (!(try currentIsMaster(zig_exe))) break :check_for_update_master;
        }
        const file = try std.fs.openFileAbsolute(last_modified_file, .{ .mode = .read_only });
        const content = try file.readToEndAlloc(alloc, MAX_INDEX_FILE_SIZE);
        defer alloc.free(content);
        if (!std.mem.eql(u8, content, last_modified.?)) {
            log.warn("Detect new versions, use `baro update` command to update.", .{});
        }
        break :check_for_update_master;
    }

    check_to_fetch_new_index_version_if_not_existed: {
        log.debug("Check to fetch new version...", .{});
        const index_file_path = try std.fmt.allocPrint(
            alloc,
            "{s}/{s}",
            .{
                runner.config.options.appdata_path.?,
                INDEX_FILE_NAME_WITH_EXT,
            },
        );
        defer alloc.free(index_file_path);
        std.fs.accessAbsolute(index_file_path, .{}) catch |err| switch (err) {
            error.FileNotFound => {
                log.debug("Write new last modified", .{});
                try std.fs.cwd().writeFile(.{
                    .data = last_modified.?,
                    .sub_path = last_modified_file,
                    .flags = .{ .truncate = false },
                });
                try fetchVerIndex(runner, alloc);
            },
            else => return err,
        };
        break :check_to_fetch_new_index_version_if_not_existed;
    }
}

/// Fetch new index version and write new last modified version
pub fn update(runner: *Runner, alloc: std.mem.Allocator, arg: Arg) !void {
    _ = arg;
    // NOTE: check the current Zig compiler version
    {
        const zig_exe = try std.fmt.allocPrint(
            alloc,
            "{s}/bin/zig",
            .{runner.config.options.appdata_path.?},
        );
        defer alloc.free(zig_exe);
        if (!(try currentIsMaster(zig_exe))) {
            log.warn(
                \\
                \\If you want to update the master version,
                \\you must be in the master version to update.
                \\Use `baro use master` to switch into the master
                \\version.
            ,
                .{},
            );
            return;
        }
    }
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
        runner.error_data = RunnerError{ .string = "last-modified" };
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
    try updateMaster(runner, alloc);
}

pub fn updateMaster(runner: *Runner, alloc: std.mem.Allocator) !void {
    const appdata_path = runner.config.options.appdata_path.?;
    // NOTE: delete old master
    {
        log.debug("Delete the old master version", .{});
        var real_file_path: [std.fs.max_path_bytes]u8 = undefined;
        const symlink_exe_path = try std.fmt.allocPrint(
            alloc,
            "{s}/master",
            .{appdata_path},
        );
        defer alloc.free(symlink_exe_path);

        const old = std.fs.readLinkAbsolute(symlink_exe_path, &real_file_path) catch |err| switch (err) {
            error.FileNotFound => {
                log.err("Master symlink is dangling. Please try to reinstall master!", .{});
                runner.error_data = .{ .string = "value of the master symlink" };
                return error.NotFound;
            },
            else => return err,
        };
        const old_dir_path = old[0 .. old.len - 4]; // NOTE: ignore /zig (len=4)
        log.debug("Old path version: {s}", .{old_dir_path});
        // NOTE: delete old dir
        {
            var dir = try std.fs.openDirAbsolute(old_dir_path, .{ .iterate = true });
            defer dir.close();
            var iter = dir.iterate();
            while (try iter.next()) |entry| {
                if (entry.kind == .directory) {
                    try dir.deleteTree(entry.name);
                } else {
                    try dir.deleteFile(entry.name);
                }
            }
            try std.fs.deleteDirAbsolute(old_dir_path);
        }

        const master_exe = try std.fmt.allocPrint(alloc, "{s}/master", .{appdata_path});
        defer alloc.free(master_exe);
        log.debug("Master exe: {s}", .{master_exe});
        try std.fs.deleteFileAbsolute(master_exe);
    }

    // NOTE: install new master version, ensure the
    //       index version is updated before
    {
        var fake_opts = std.StringHashMap(cli.Arg.Option).init(alloc);
        defer fake_opts.deinit();
        try install(runner, alloc, .{
            .options = fake_opts,
            .value = "master",
        });
    }
}

pub fn clean(runner: *cli.Runner, alloc: std.mem.Allocator, arg: Arg) !void {
    log.info("Cleaning {s} version dir...", .{arg.value.?});
    const appdata_path = runner.config.options.appdata_path.?;
    const version = getVersionFromSemverString(
        alloc,
        runner,
        arg.value.?,
        INDEX_FILE_NAME_WITH_EXT,
    ) catch |err| switch (err) {
        error.VerNotFound => {
            runner.error_data = .{
                .allocated_string = try std.fmt.allocPrint(
                    alloc,
                    "The zig compiler version `{s}`",
                    .{arg.value.?},
                ),
            };
            return error.NotFound;
        },
        else => return err,
    };
    defer alloc.free(version);

    const dir_path = try std.fmt.allocPrint(alloc, "{s}/zig-{s}", .{
        appdata_path,
        version,
    });
    defer alloc.free(dir_path);
    std.fs.accessAbsolute(dir_path, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            runner.error_data = .{
                .allocated_string = try std.fmt.allocPrint(
                    alloc,
                    "The zig compiler version `{s}`",
                    .{arg.value.?},
                ),
            };
            return error.NotInstalled;
        },
        else => return err,
    };

    var dir = try std.fs.openDirAbsolute(dir_path, .{ .iterate = true });
    defer dir.close();
    var iter = dir.iterate();

    while (try iter.next()) |entry| {
        if (entry.kind == .directory) {
            try dir.deleteTree(entry.name);
        } else {
            try dir.deleteFile(entry.name);
        }
    }
    try std.fs.deleteDirAbsolute(dir_path);
    if (std.mem.eql(u8, arg.value.?, "master")) {
        const master_exe = try std.fmt.allocPrint(alloc, "{s}/master", .{appdata_path});
        defer alloc.free(master_exe);
        log.debug("Master exe: {s}", .{master_exe});
        try std.fs.deleteFileAbsolute(master_exe);
    }
    log.info("Done!", .{});
}

pub fn currentIsMaster(zig_exe: []const u8) !bool {
    var realpath_buf: [std.fs.max_path_bytes]u8 = undefined;
    const realpath = std.fs.readLinkAbsolute(
        zig_exe,
        &realpath_buf,
    ) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    var split = std.mem.splitScalar(u8, realpath, '/');
    const maybe_master = split.buffer[split.buffer.len - 6 ..];
    return std.mem.eql(u8, maybe_master, "master");
}

pub fn fetchVerIndex(runner: *Runner, alloc: Allocator) !void {
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
        runner.error_data = RunnerError{ .string = "version index of the Zig compiler" };
        return error.FetchingFailed;
    }

    const index_file_path = try std.fmt.allocPrint(
        alloc,
        "{s}/{s}",
        .{
            runner.config.options.appdata_path.?,
            INDEX_FILE_NAME_WITH_EXT,
        },
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

pub fn install(runner: *Runner, alloc: Allocator, arg: Arg) !void {
    log.info("Check version index...", .{});
    const appdata_path = runner.config.options.appdata_path.?;
    const index_file_path = try std.fmt.allocPrint(
        alloc,
        "{s}/{s}",
        .{ appdata_path, INDEX_FILE_NAME_WITH_EXT },
    );
    defer alloc.free(index_file_path);

    // NOTE: Take tarball link, zig version from the index file
    const index_file = std.fs.openFileAbsolute(index_file_path, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            log.warn(
                \\
                \\Version file index not found.
                \\You need to enable Zigc in configuration to automatically
                \\fetch new one.
            , .{});
            return;
        },
        else => return err,
    };
    defer index_file.close();

    const raw = try index_file.readToEndAlloc(alloc, MAX_INDEX_FILE_SIZE);
    defer alloc.free(raw);

    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, raw, .{});
    defer parsed.deinit();
    const value: std.json.Value = parsed.value;
    const root = value.object.get(arg.value orelse unreachable) orelse {
        runner.error_data = .{ .allocated_string = try std.fmt.allocPrint(
            alloc,
            "The zig compiler version `{s}`",
            .{arg.value.?},
        ) };
        return error.NotFound;
    };

    const builtin = @import("builtin");
    const @"arch-os" = try std.fmt.allocPrint(
        alloc,
        "{s}-{s}",
        .{ @tagName(builtin.cpu.arch), @tagName(builtin.os.tag) },
    );
    const src = root.object.get(@"arch-os") orelse {
        runner.error_data = RunnerError{ .allocated_string = @"arch-os" };
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
    const output_dir = try std.fmt.allocPrint(alloc, "{s}/zig-{s}", .{ appdata_path, version });
    defer alloc.free(output_dir);
    if (std.fs.accessAbsolute(output_dir, .{})) |_| {
        log.err("the Zig compiler version `{s}` have been installed!", .{version});
        return;
    } else |err| {
        switch (err) {
            error.FileNotFound => {},
            else => return err,
        }
    }

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

    const tar_file_path = try std.fmt.allocPrint(
        alloc,
        "{s}/zig-{s}.tar.xz",
        .{ appdata_path, version },
    );
    defer alloc.free(tar_file_path);
    const file = try std.fs.cwd().createFile(tar_file_path, .{});
    defer file.close();

    var buffer: [8192]u8 = undefined;
    var total_bytes: usize = 0;
    while (true) {
        const byte_read = try req.read(&buffer);
        if (byte_read == 0) break;
        try file.writeAll(buffer[0..byte_read]);
        total_bytes += byte_read;
    }
    try std.fs.makeDirAbsolute(output_dir);
    try utils.extractTarFile(alloc, log, tar_file_path, output_dir);
    try std.fs.deleteFileAbsolute(tar_file_path);
    if (std.mem.eql(u8, arg.value.?, "master")) {
        const zig_master_exe = try std.fmt.allocPrint(alloc, "{s}/zig", .{output_dir});
        defer alloc.free(zig_master_exe);
        const master_symlink = try std.fmt.allocPrint(alloc, "{s}/master", .{appdata_path});
        defer alloc.free(master_symlink);
        try std.fs.symLinkAbsolute(zig_master_exe, master_symlink, .{});
    }
    log.info("Clean the tar file!", .{});
}

pub fn listAllInstalledVersions(
    runner: *Runner,
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
            try list.append(split.rest());
        }
    }

    log.info("\r\nAll installed versions:", .{});
    for (list.items[0..]) |it| {
        std.debug.print("- {s}\r\n", .{it});
    }
}

pub fn listAllAvailableVersions(
    runner: *Runner,
    alloc: Allocator,
    arg: Arg,
) !void {
    _ = arg;
    const appdata_path = runner.config.options.appdata_path.?;
    const index_file_path = try std.fmt.allocPrint(
        alloc,
        "{s}/{s}",
        .{ appdata_path, INDEX_FILE_NAME_WITH_EXT },
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

pub fn use(
    runner: *Runner,
    alloc: Allocator,
    arg: Arg,
) !void {
    const appdata_path = runner.config.options.appdata_path.?;
    // NOTE: Take zig version from the index file
    const version = getVersionFromSemverString(
        alloc,
        runner,
        arg.value orelse unreachable,
        INDEX_FILE_NAME_WITH_EXT,
    ) catch |err| switch (err) {
        error.VerNotFound => {
            runner.error_data = RunnerError{
                .allocated_string = try std.fmt.allocPrint(
                    alloc,
                    "The zig compiler version `{s}`",
                    .{arg.value.?},
                ),
            };
            return error.NotFound;
        },
        else => return err,
    };
    defer alloc.free(version);

    const exe = blk: {
        if (std.mem.eql(u8, arg.value.?, "master")) {
            break :blk try std.fmt.allocPrint(
                alloc,
                "{s}/master",
                .{appdata_path},
            );
        } else {
            break :blk try std.fmt.allocPrint(
                alloc,
                "{s}/zig-{s}/zig",
                .{ appdata_path, version },
            );
        }
    };
    defer alloc.free(exe);
    std.log.debug("Exe path: {s}", .{exe});

    // NOTE: check if specified zig version is
    //       available in the index file
    std.fs.accessAbsolute(exe, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            runner.error_data = RunnerError{
                .allocated_string = try std.fmt.allocPrint(
                    alloc,
                    "The zig compiler installed version `{s}`",
                    .{version},
                ),
            };
            return error.NotFound;
        },
        else => return err,
    };

    const bin_dir = try std.fmt.allocPrint(
        alloc,
        "{s}/bin",
        .{appdata_path},
    );
    defer alloc.free(bin_dir);
    std.fs.accessAbsolute(bin_dir, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            std.log.debug("Create the new bin folder.", .{});
            try std.fs.makeDirAbsolute(bin_dir);
        },
        else => return err,
    };

    const zig_bin = try std.fmt.allocPrint(
        alloc,
        "{s}/bin/zig",
        .{runner.config.options.appdata_path.?},
    );
    defer alloc.free(zig_bin);
    // NOTE: remove zig_bin if its existed
    if (std.fs.accessAbsolute(zig_bin, .{})) |v| {
        _ = v;
        try std.fs.deleteFileAbsolute(zig_bin);
    } else |err| {
        switch (err) {
            error.FileNotFound => {},
            else => return err,
        }
    }

    // NOTE: symlink exe to
    try std.fs.symLinkAbsolute(exe, zig_bin, .{});
}

pub fn getVersionFromSemverString(
    alloc: std.mem.Allocator,
    runner: *Runner,
    semver: []const u8,
    index_file_path: []const u8,
) ![]const u8 {
    const path = try std.fmt.allocPrint(alloc, "{s}/{s}", .{
        runner.config.options.appdata_path.?,
        index_file_path,
    });
    defer alloc.free(path);
    const index_file = try std.fs.openFileAbsolute(path, .{});
    defer index_file.close();

    const raw = try index_file.readToEndAlloc(alloc, MAX_INDEX_FILE_SIZE);
    defer alloc.free(raw);

    // NOTE: check if zig version is available
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, raw, .{});
    defer parsed.deinit();
    const value: std.json.Value = parsed.value;
    const root = value.object.get(semver) orelse
        return error.VerNotFound;

    const version = blk: {
        if (std.mem.eql(u8, semver, "master")) {
            break :blk (root.object.get("version") orelse unreachable).string;
        } else {
            break :blk semver;
        }
    };
    return alloc.dupe(u8, version);
}
