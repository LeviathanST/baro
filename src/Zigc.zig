const std = @import("std");
const known_folders = @import("known_folders");

const utils = @import("utils.zig");
const cli = @import("cli.zig");

const Runner = cli.Runner;
const RunnerError = cli.Runner.Error;
const Allocator = std.mem.Allocator;

const Manager = @import("tool.zig").Manager;
const ScopedManager = Manager(.zig_compiler);
const Arg = @import("cli.zig").Arg;

const Zigc = @This();

runner: *Runner,
manager: ScopedManager,

const INDEX_URL = "https://ziglang.org/download/index.json";
const MAX_INDEX_FILE_SIZE = 1024 * 100; // 100mb

pub fn init(r: *Runner, sub_path: []const u8) Zigc {
    return .{
        .runner = r,
        .manager = Manager(.zig_compiler).init(r, sub_path),
    };
}

pub fn checkForUpdate(self: Zigc, alloc: Allocator) !void {
    const zig_exe = try std.fmt.allocPrint(
        alloc,
        "{s}/bin/zig",
        .{self.runner.config.options.appdata_path.?},
    );
    defer alloc.free(zig_exe);

    try self.manager.checkForUpdate(
        INDEX_URL,
        zig_exe,
    );
}

/// Fetch new index version and write new last modified version
pub fn update(ptr: *anyopaque, alloc: std.mem.Allocator, arg: Arg) !void {
    _ = arg;
    const self: *Zigc = @ptrCast(@alignCast(ptr));
    const log = @TypeOf(self.manager).log;
    // NOTE: check the current Zig compiler version
    {
        const zig_exe = try std.fmt.allocPrint(
            alloc,
            "{s}/bin/zig",
            .{self.runner.config.options.appdata_path.?},
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
    const info = self.manager.info();
    var list = try self.getVersionAndDowloadLinkFromIndexFile(alloc, "master");
    defer {
        for (list.items) |item| {
            alloc.free(item);
        }
        list.deinit(alloc);
    }

    var master_info = try info.masterInfo(alloc);
    defer master_info.deinit();

    try self.manager.update(
        master_info.symlink_path,
        master_info.dir_path,
        INDEX_URL,
        list.items[1],
        list.items[0],
    );
}

pub fn clean(ptr: *anyopaque, alloc: std.mem.Allocator, arg: Arg) !void {
    const self: *Zigc = @ptrCast(@alignCast(ptr));
    const info = self.manager.info();
    const data_path = try info.data_path(alloc);
    defer alloc.free(data_path);
    const log = @TypeOf(self.manager).log;
    log.info("Cleaning {s} version dir...", .{arg.value.?});

    const version = getVersionFromSemverString(
        alloc,
        self.manager,
        arg.value.?,
    ) catch |err| switch (err) {
        error.VerNotFound => {
            self.runner.error_data = .{
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

    const dir_path = try std.fmt.allocPrint(alloc, "{s}/{s}-{s}", .{
        data_path,
        info.prefix,
        version,
    });
    defer alloc.free(dir_path);
    try self.manager.clean(version, dir_path);
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

pub fn fetchVerIndex(self: Zigc, _: Allocator) !void {
    self.manager.fetchVerIndex(
        "https://ziglang.org/download/index.json",
    ) catch |err| switch (err) {
        error.FetchingFailed => {
            self.runner.error_data = .{ .string = "Zig compiler verison index" };
            return err;
        },
        else => return err,
    };
}

pub fn install(ptr: *anyopaque, alloc: Allocator, arg: Arg) !void {
    const self: *Zigc = @ptrCast(@alignCast(ptr));
    const log = @TypeOf(self.manager).log;
    const info = self.manager.info();
    const data_path = try info.data_path(alloc);
    defer alloc.free(data_path);

    log.info("Check version index...", .{});
    var list = try self.getVersionAndDowloadLinkFromIndexFile(alloc, arg.value.?);
    defer {
        for (list.items) |item| {
            alloc.free(item);
        }
        list.deinit(alloc);
    }
    const version = list.items[1];
    const download_link = list.items[0];

    const output_dir = try std.fmt.allocPrint(
        alloc,
        "{s}/{s}-{s}",
        .{ data_path, info.prefix, version },
    );
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

    try self.manager.install(
        version,
        download_link,
        std.mem.eql(u8, arg.value.?, "master"),
    );
}

pub fn listAllInstalledVersions(
    ptr: *anyopaque,
    _: Allocator,
    _: Arg,
) !void {
    const self: *Zigc = @ptrCast(@alignCast(ptr));
    try self.manager.listAllInstalledVersions();
}

pub fn listAllAvailableVersions(
    ptr: *anyopaque,
    alloc: Allocator,
    arg: Arg,
) !void {
    _ = arg;
    const self: *Zigc = @ptrCast(@alignCast(ptr));
    const log = @TypeOf(self.manager).log;
    const info = self.manager.info();
    const data_path = try info.data_path(alloc);
    defer alloc.free(data_path);
    const index_file_path = try info.getIndexFilePath(alloc);
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

pub fn use(ptr: *anyopaque, alloc: Allocator, arg: Arg) !void {
    const self: *Zigc = @ptrCast(@alignCast(ptr));
    const log = @TypeOf(self.manager).log;
    const info = self.manager.info();
    const tool_data_path = try info.data_path(alloc);
    defer alloc.free(tool_data_path);
    // NOTE: Take zig version from the index file
    const version = getVersionFromSemverString(
        alloc,
        self.manager,
        arg.value orelse unreachable,
    ) catch |err| switch (err) {
        error.VerNotFound => {
            self.runner.error_data = RunnerError{
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
                .{tool_data_path},
            );
        } else {
            break :blk try std.fmt.allocPrint(
                alloc,
                "{s}/{s}-{s}/zig",
                .{ tool_data_path, info.prefix, version },
            );
        }
    };
    defer alloc.free(exe);
    log.debug("Exe path: {s}", .{exe});

    try self.manager.use(version, exe, "zig");
}

fn getVersionFromSemverString(
    alloc: std.mem.Allocator,
    manager: ScopedManager,
    semver: []const u8,
) ![]const u8 {
    const index_file_path = try manager.info().getIndexFilePath(alloc);
    defer alloc.free(index_file_path);
    const index_file = try std.fs.openFileAbsolute(index_file_path, .{});
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

/// Get version `(index 1)` and download link `(index 0)`
/// into an array.
/// All children of the array should be freed after finish.
fn getVersionAndDowloadLinkFromIndexFile(
    self: Zigc,
    alloc: std.mem.Allocator,
    semver: []const u8,
) !std.array_list.Aligned([]const u8, null) {
    const log = @TypeOf(self.manager).log;
    const index_file_path = try self.manager.info().getIndexFilePath(alloc);
    defer alloc.free(index_file_path);

    const index_file = std.fs.openFileAbsolute(index_file_path, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            log.warn(
                \\
                \\Version file index not found. (path: {s})
                \\You need to enable Zigc in configuration to automatically
                \\fetch new one.
            , .{index_file_path});
            return error.FileNotFound;
        },
        else => return err,
    };
    defer index_file.close();

    const raw = try index_file.readToEndAlloc(alloc, MAX_INDEX_FILE_SIZE);
    defer alloc.free(raw);

    var list = try std.array_list.Aligned([]const u8, null).initCapacity(alloc, 2);
    errdefer list.deinit(alloc);
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, raw, .{});
    defer parsed.deinit();
    const value: std.json.Value = parsed.value;
    const root = value.object.get(semver) orelse {
        self.runner.error_data = .{ .allocated_string = try std.fmt.allocPrint(
            alloc,
            "The zig compiler version `{s}`",
            .{semver},
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
        self.runner.error_data = RunnerError{ .allocated_string = @"arch-os" };
        return error.Unsupported;
    };
    defer alloc.free(@"arch-os"); // NOTE: defer here to make sure `arch-os` is supported.

    const tarball_link = try alloc.dupe(u8, (src.object.get("tarball") orelse unreachable).string);
    try list.append(alloc, tarball_link); // 0

    const version = blk: {
        if (std.mem.eql(u8, "master", semver)) {
            break :blk try alloc.dupe(u8, (root.object.get("version") orelse unreachable).string);
        } else {
            break :blk try alloc.dupe(u8, semver);
        }
    };
    try list.append(alloc, version); // 1
    return list;
}
