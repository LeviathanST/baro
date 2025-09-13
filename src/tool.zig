//! The helper to manage tools (zigc, zls, your custom tools).
//!
//! *NOTE: All things start with $ is a custom value. (e.g $prefix, ...)*
//!
//! # Manager:
//!  ## Index version:
//!  - All functions in this feature are almost called from another.
//!  - The file contains versions string, download link, and some extra information
//!  (total bytes, hash sign, ...).
//!  - **Auto fetch:** the file will be fetched when we are using `checkForUpdate()`
//!  if none exists.
//!
//!  ## Install:
//!   ### install()
//!   - Fetch a tarball and write it to a local file, then we extract the tarball and
//!   clean up.
//!
//!  ## Update:
//!   ### checkForUpdate()
//!   - **Auto check new timestamp:** Send a `HEAD` http request to index page
//!   (ziglang.org/download/index.json, github tags) and compare `Last-Modified`
//!   from http response headers with stored `last-modified` in cache file.
//!   - **Notification (master only):** Log notification if new version is detected.
//!   - **Auto write new**: write new `last-modified` cache and fetch new version index if
//!   `last-modified` isn't exists. *(To make they are sync, we fetch and write both)*
//!   ### update()
//!   - Remove the old master and write new one via `install()`.
//!   - Errors occur when our current branch is not master.
//!
//!  ## List versions:
//!   ### listAllInstalledVersions():
//!   - **Get all versions** in the tool data ($appdata/$prefix) and print.
//!   - Currently, we can have many things at the same tool data (index file,
//!   source code folders, ...), so we have to identify source code folders by a
//!   random prefix (btw, I choose `info.prefix`).
//!
//!  ## Clean versions:
//!   ### clean():
//!   - Clean `the version directory` and children.
//!
//! # Tool information:
//!  + Prefix
//!  + Data path       (e.g $appdata/$prefix)
//!  + Index file path (e.g $appdata/$prefix/index.json)
//!  + cache instance  (via `info.cache()`)
//!
//! # Cache:
//!  - Read a `key` - `value` pair
//!  - Write a `key` - `value` pair
const std = @import("std");
const cli = @import("cli.zig");
const utils = @import("utils.zig");

const Config = @import("Config.zig");
const Runner = cli.Runner;
const Allocator = std.mem.Allocator;

pub fn Manager(comptime scoped: @TypeOf(.literal_enum)) type {
    return struct {
        pub const log = std.log.scoped(scoped);
        const ScopedManager = @This();
        /// The runner is almost used to set error message.
        runner: *Runner,
        /// Used in:
        /// + appdata/sub_path
        prefix: []const u8,

        pub fn init(r: *Runner, sub_path: []const u8) ScopedManager {
            return .{
                .runner = r,
                .prefix = sub_path,
            };
        }

        pub const MAX_INDEX_FILE_SIZE = 1024 * 100; // 100mb

        /// Only notify new master version.
        ///
        /// Use a `HEAD` request and check `Last-Modified`
        /// from http headers then compare content in cache file.
        /// Write new `last-modified` and fetch new `index version`
        /// if one of them is not existed.
        pub fn checkForUpdate(
            self: ScopedManager,
            index_url: []const u8,
            last_modified_url: []const u8,
            current_exe_path: []const u8,
        ) !void {
            const alloc = self.runner.allocator;
            log.debug("Check new master version", .{});

            const last_modified = try getRemoteLastModified(alloc, last_modified_url);
            defer if (last_modified != null) alloc.free(last_modified.?);

            // Write new last-modified in cache file
            // and fetch new version index to sync in both.
            const cache = try self.info().cache();
            if (cache.wrote_new) {
                _ = try cache.write(alloc, "last_modified", last_modified.?);
                try self.fetchVerIndex(index_url);
            }

            check_for_update_master: {
                // only notify in master branch
                if (!(try currentIsMaster(current_exe_path))) break :check_for_update_master;
                const content = try cache.read(alloc, "last_modified");
                defer alloc.free(content);
                if (!std.mem.eql(u8, content, last_modified.?)) {
                    log.warn("Detect the new master version, use `baro update` command to update.", .{});
                }
                break :check_for_update_master;
            }

            try self.fetchNewVerIndexIfNotExisted(
                last_modified.?,
                cache.path,
                index_url,
            );
        }

        fn currentIsMaster(symlink_exe: []const u8) !bool {
            var realpath_buf: [std.fs.max_path_bytes]u8 = undefined;
            const realpath = std.fs.readLinkAbsolute(
                symlink_exe,
                &realpath_buf,
            ) catch |err| switch (err) {
                error.FileNotFound => return false,
                else => return err,
            };
            var split = std.mem.splitScalar(u8, realpath, '/');
            const maybe_master = split.buffer[split.buffer.len - 6 ..];
            return std.mem.eql(u8, maybe_master, "master");
        }

        /// Fetch new version index and write new last-modified
        fn fetchNewVerIndexIfNotExisted(
            self: ScopedManager,
            last_modified: []const u8,
            cache_file: []const u8,
            url: []const u8,
        ) !void {
            const alloc = self.runner.allocator;
            const tool_data_path = try self.info().data_path(alloc);
            defer alloc.free(tool_data_path);

            log.debug("Check to fetch new version...", .{});
            const index_file_path = try self.info().getIndexFilePath(alloc);
            defer alloc.free(index_file_path);

            const new_file_is_created = try utils.initFsIfNotExists(
                .file,
                cache_file,
                .{ .default_data = last_modified },
            );
            const cache = try self.info().cache();
            const wrote_new_last_modified = try cache.write(alloc, "last_modified", last_modified);
            if (new_file_is_created or wrote_new_last_modified) {
                try self.fetchVerIndex(url);
            }
        }

        /// `error.FetchingFailed` occurs when http
        /// response `status code != .ok`, the caller
        /// need to catch and set `error_data`.
        fn fetchVerIndex(
            self: ScopedManager,
            url: []const u8,
        ) !void {
            const alloc = self.runner.allocator;
            const tool_data_path = try self.info().data_path(alloc);
            defer alloc.free(tool_data_path);
            log.info("Fetching new version index...", .{});

            var http_client = std.http.Client{
                .allocator = alloc,
            };
            defer http_client.deinit();
            var writer_alloc = std.io.Writer.Allocating.init(alloc);
            defer writer_alloc.deinit();

            const fetch_result = try http_client.fetch(.{
                .method = .GET,
                .response_writer = &writer_alloc.writer,
                .location = .{ .url = url },
            });
            if (fetch_result.status != .ok)
                return error.FetchingFailed;

            const index_file_path = try self.info().getIndexFilePath(alloc);
            defer alloc.free(index_file_path);
            _ = std.fs.openDirAbsolute(tool_data_path, .{}) catch |err| switch (err) {
                error.FileNotFound => {
                    try std.fs.makeDirAbsolute(tool_data_path);
                },
                else => return err,
            };

            log.info("Index file path: {s}", .{index_file_path});
            try std.fs.cwd().writeFile(.{
                .sub_path = index_file_path,
                .data = writer_alloc.written(),
                .flags = .{ .truncate = false },
            });
            log.info("Fetching successfully!", .{});
        }

        /// Fetch new index version and write new last modified version
        pub fn update(
            self: ScopedManager,
            old_master_exe: []const u8,
            old_master_dir: []const u8,
            index_url: []const u8,
            master_version: []const u8,
            download_link: []const u8,
        ) !void {
            const alloc = self.runner.allocator;
            const last_modified = try getRemoteLastModified(alloc, index_url);
            defer if (last_modified != null) alloc.free(last_modified.?);
            if (last_modified == null) {
                self.runner.error_data = .{ .string = "last-modified" };
                return error.NotFound;
            }
            try self.fetchVerIndex(index_url);

            const cache = try self.info().cache();
            _ = try cache.write(alloc, "last_modified", last_modified.?);

            try self.updateMaster(
                old_master_exe,
                old_master_dir,
                master_version,
                download_link,
            );
        }

        pub fn updateMaster(
            self: ScopedManager,
            old_master_exe: []const u8,
            old_master_dir: []const u8,
            master_version: []const u8,
            download_link: []const u8,
        ) !void {
            const alloc = self.runner.allocator;

            // NOTE: delete old master
            {
                log.debug("Old path version: {s}", .{old_master_dir});
                // NOTE: delete old dir
                {
                    var dir = try std.fs.openDirAbsolute(old_master_dir, .{ .iterate = true });
                    defer dir.close();
                    var iter = dir.iterate();
                    while (try iter.next()) |entry| {
                        if (entry.kind == .directory) {
                            try dir.deleteTree(entry.name);
                        } else {
                            try dir.deleteFile(entry.name);
                        }
                    }
                    try std.fs.deleteDirAbsolute(old_master_dir);
                }

                log.debug("Master exe: {s}", .{old_master_exe});
                try std.fs.deleteFileAbsolute(old_master_exe);
            }

            // NOTE: install new master version, ensure the
            //       index version is updated
            {
                const data_path = try self.info().data_path(alloc);
                defer alloc.free(data_path);
                try self.install(
                    master_version,
                    download_link,
                    true,
                );
            }
        }

        pub fn listAllInstalledVersions(
            self: ScopedManager,
        ) !void {
            const alloc = self.runner.allocator;
            const info1 = self.info();

            const data_path = try info1.data_path(alloc);
            defer alloc.free(data_path);
            const data_dir = try std.fs.openDirAbsolute(data_path, .{ .iterate = true });
            var dir_iter = data_dir.iterate();

            const prefix = try std.fmt.allocPrint(alloc, "{s}-", .{info1.prefix});
            defer alloc.free(prefix);

            log.info("\r\nAll installed versions:", .{});
            while (try dir_iter.next()) |item| {
                if (item.kind == .directory and std.mem.startsWith(u8, item.name, prefix)) {
                    var split = std.mem.splitScalar(u8, item.name, '-');
                    _ = split.first(); // skip `zig-`
                    std.debug.print("- {s}\r\n", .{split.rest()});
                }
            }
        }

        /// The caller should `free()` memory the return value
        /// after finish.
        fn getRemoteLastModified(alloc: std.mem.Allocator, url: []const u8) !?[]const u8 {
            var http_client: std.http.Client = .{ .allocator = alloc };
            defer http_client.deinit();
            var req = try http_client.request(
                .HEAD,
                try .parse(url),
                .{},
            );
            defer req.deinit();
            try req.sendBodiless();

            var buf: [512]u8 = undefined;
            var headers = (try req.receiveHead(&buf)).head.iterateHeaders();
            while (headers.next()) |header| {
                if (std.ascii.eqlIgnoreCase(header.name, "last-modified")) {
                    return try alloc.dupe(u8, header.value);
                }
            }
            return null;
        }

        pub fn install(
            self: ScopedManager,
            version: []const u8,
            download_link: []const u8,
            is_master: bool,
        ) !void {
            const alloc = self.runner.allocator;
            const tool_data_path = try self.info().data_path(alloc);
            defer alloc.free(tool_data_path);

            // Download tarball file
            var http_client: std.http.Client = .{ .allocator = alloc };
            defer http_client.deinit();

            log.info("Download from {s}", .{download_link});
            var rw = std.io.Writer.Allocating.init(alloc);
            defer rw.deinit();
            const req = try http_client.fetch(.{
                .method = .GET,
                .location = .{ .url = download_link },
                .response_writer = &rw.writer,
            });
            if (req.status != .ok) return error.FetchingFailed;

            // create tarfile in local
            const tar_file_path = try std.fmt.allocPrint(
                alloc,
                "{s}/download-{s}.tar.xz",
                .{ tool_data_path, version },
            );
            defer alloc.free(tar_file_path);
            const file = try std.fs.cwd().createFile(tar_file_path, .{});
            defer file.close();

            // streaming content to file
            var total_bytes: usize = 0;
            const content = try rw.toOwnedSlice();
            defer alloc.free(content);

            while (total_bytes < content.len) {
                const read = try file.write(content[total_bytes..]);
                total_bytes += read;
            }

            // create output dir
            const output_dir = try std.fmt.allocPrint(
                alloc,
                "{s}/{s}-{s}",
                .{ tool_data_path, self.info().prefix, version },
            );
            defer alloc.free(output_dir);
            try std.fs.makeDirAbsolute(output_dir);

            // extract and delete the tarball
            try utils.extractTarFile(alloc, log, tar_file_path, output_dir);
            try std.fs.deleteFileAbsolute(tar_file_path);
            log.debug("Clean the tar file!", .{});

            // Assign master exe to $appdata/$prefix/master
            if (is_master) {
                const zig_master_exe = try std.fmt.allocPrint(alloc, "{s}/zig", .{output_dir});
                defer alloc.free(zig_master_exe);
                const master_symlink = try std.fmt.allocPrint(
                    alloc,
                    "{s}/master",
                    .{tool_data_path},
                );
                defer alloc.free(master_symlink);
                std.log.debug("{s}", .{master_symlink});

                // remove `symlink` if it already exists
                if (std.fs.accessAbsolute(master_symlink, .{})) |_| {
                    log.debug("Delete the old `bin` ({s})", .{master_symlink});
                    try std.fs.deleteFileAbsolute(master_symlink);
                } else |err| {
                    switch (err) {
                        error.FileNotFound => {},
                        else => return err,
                    }
                }
                try std.fs.symLinkAbsolute(zig_master_exe, master_symlink, .{});
            }
        }

        pub fn use(
            self: ScopedManager,
            version: []const u8,
            exe_path: []const u8,
            /// The binary file name
            /// (e.g zig -> /bin/zig)
            bin_name: []const u8,
        ) !void {
            const alloc = self.runner.allocator;
            const app_data_path = self.info()._app_data_path;
            std.log.debug("Exe path: {s}", .{exe_path});

            // check if the executable is available
            std.fs.accessAbsolute(exe_path, .{}) catch |err| switch (err) {
                error.FileNotFound => {
                    self.runner.error_data = .{
                        .allocated_string = try std.fmt.allocPrint(
                            alloc,
                            "The zig compiler version `{s}`",
                            .{version},
                        ),
                    };
                    return error.NotInstalled;
                },
                else => return err,
            };

            const bin_dir = try std.fmt.allocPrint(
                alloc,
                "{s}/bin",
                .{app_data_path},
            );
            defer alloc.free(bin_dir);
            std.fs.accessAbsolute(bin_dir, .{}) catch |err| switch (err) {
                error.FileNotFound => {
                    log.debug("Create the new bin folder.", .{});
                    try std.fs.makeDirAbsolute(bin_dir);
                },
                else => return err,
            };

            const bin = try std.fmt.allocPrint(
                alloc,
                "{s}/bin/{s}",
                .{ app_data_path, bin_name },
            );
            defer alloc.free(bin);

            // remove `bin` if it already exists
            if (std.fs.accessAbsolute(bin, .{})) |_| {
                log.debug("Delete the old `bin` ({s})", .{bin});
                try std.fs.deleteFileAbsolute(bin);
            } else |err| {
                switch (err) {
                    error.FileNotFound => {},
                    else => return err,
                }
            }

            try std.fs.symLinkAbsolute(exe_path, bin, .{});
        }

        /// Clean `version directory`
        pub fn clean(self: ScopedManager, version: []const u8, dir_path: []const u8) !void {
            const alloc = self.runner.allocator;
            const data_path = try self.info().data_path(alloc);
            defer alloc.free(data_path);

            std.fs.accessAbsolute(dir_path, .{}) catch |err| switch (err) {
                error.FileNotFound => {
                    self.runner.error_data = .{
                        .allocated_string = try std.fmt.allocPrint(
                            alloc,
                            "The zig compiler version `{s}`",
                            .{version},
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
            if (std.mem.eql(u8, version, "master")) {
                const master_exe = try std.fmt.allocPrint(alloc, "{s}/master", .{data_path});
                defer alloc.free(master_exe);
                log.debug("Master exe: {s}", .{master_exe});
                try std.fs.deleteFileAbsolute(master_exe);
            }
        }

        pub fn info(self: ScopedManager) Info {
            const config_opts = self.runner.config.options;
            return .{
                .prefix = self.prefix,
                ._app_data_path = config_opts.appdata_path.?,
                ._cache_path = config_opts.cache_path.?,
            };
        }
    };
}

/// Tool information:
/// + Data path       (e.g $appdata/zigc)
/// + Index file path (e.g $appdata/zigc/index.json)
pub const Info = struct {
    /// This is used to:
    /// + identify field data in cache (prefix_field)
    /// + prefix file name (prefix-file)
    prefix: []const u8,
    _index_file_name: []const u8 = "index.json",
    _cache_path: []const u8,
    _app_data_path: []const u8,

    pub const MasterInfo = struct {
        exe_path: []const u8,
        dir_path: []const u8,
        symlink_path: []const u8,
        _alloc: std.mem.Allocator,

        pub fn deinit(self: *MasterInfo) void {
            self._alloc.free(self.exe_path);
            self._alloc.free(self.dir_path);
            self._alloc.free(self.symlink_path);
        }
    };

    pub fn cache(self: Info) !Cache {
        const wn = try utils.initFsIfNotExists(
            .file,
            self._cache_path,
            .{ .default_data = "{}" },
        );

        return .{
            .path = self._cache_path,
            .wrote_new = wn,
            ._prefix = self.prefix,
        };
    }

    /// The caller should `alloc.free()` the returns value after finish.
    pub fn getIndexFilePath(self: Info, alloc: std.mem.Allocator) ![]const u8 {
        const dp = try self.data_path(alloc);
        defer alloc.free(dp);
        return std.fmt.allocPrint(alloc, "{s}/{s}", .{ dp, self._index_file_name });
    }

    /// Read the master exe real path via symlink.
    pub fn masterInfo(self: Info, alloc: std.mem.Allocator) !MasterInfo {
        const dp = try self.data_path(alloc);
        defer alloc.free(dp);
        const symlink_exe_path = try std.fmt.allocPrint(
            alloc,
            "{s}/master",
            .{dp},
        );
        var real_file_path: [std.fs.max_path_bytes]u8 = undefined;
        const master_exe = try std.fs.readLinkAbsolute(
            symlink_exe_path,
            &real_file_path,
        );
        return .{
            .exe_path = try alloc.dupe(u8, master_exe),
            .dir_path = try alloc.dupe(u8, master_exe[0 .. master_exe.len - 4]), // minus "/zig".len
            .symlink_path = symlink_exe_path,
            ._alloc = alloc,
        };
    }

    /// Get tool data path (e.g `$appdata/zigc/`).
    /// The caller should `alloc.free()` the returns value after finish.
    pub fn data_path(self: Info, alloc: std.mem.Allocator) ![]u8 {
        const path = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ self._app_data_path, self.prefix });
        errdefer alloc.free(path);
        _ = try utils.initFsIfNotExists(.dir, path, .{});
        return path;
    }
};

/// Every time we use `info.cache()` and if it doesnt exists,
/// the cache file will be created automatically.
///
/// Currently, we just need to store tools's `last-modified`,
/// so it should be simplicity.
const Cache = struct {
    path: []const u8,
    /// Track to the session wrote new one.
    wrote_new: bool,
    _prefix: []const u8 = "",
    const CacheFields = struct { zigc_last_modified: ?[]const u8 = null };

    /// If `key` already has value, its value should be replaced into
    /// the new one.
    /// `error.InvalidField` is returned when the `key` is not available
    /// in `CacheField`.
    pub fn write(
        self: Cache,
        alloc: std.mem.Allocator,
        key: []const u8,
        value: []const u8,
    ) !bool {
        const formatted_key = try std.fmt.allocPrint(alloc, "{s}_{s}", .{ self._prefix, key });
        defer alloc.free(formatted_key);

        const file = try std.fs.openFileAbsolute(self.path, .{ .mode = .read_write });
        defer file.close();
        const content = try file.readToEndAlloc(alloc, 1024); // 1mb
        defer alloc.free(content);

        // get all contents in the cache file.
        const parsed: std.json.Parsed(CacheFields) = try std.json.parseFromSlice(
            CacheFields,
            alloc,
            content,
            .{
                .allocate = .alloc_if_needed,
                .ignore_unknown_fields = true,
                .duplicate_field_behavior = .use_last,
            },
        );
        defer parsed.deinit();
        var v = parsed.value;

        // stringify the value with new `value`
        inline for (std.meta.fields(CacheFields)) |f| {
            if (std.mem.eql(u8, f.name, formatted_key)) {
                // skip to replace the old value into
                // the new one if they are the same.
                if (@field(v, f.name)) |old|
                    if (std.mem.eql(u8, old, value)) return false;

                @field(v, f.name) = value;
                const json_fmt = std.json.fmt(v, .{ .whitespace = .indent_4 });
                var alloc_writer = std.io.Writer.Allocating.init(alloc);
                defer alloc_writer.deinit();
                try json_fmt.format(&alloc_writer.writer);

                try file.seekTo(0);
                _ = try file.write(alloc_writer.written());
                return true;
            }
        }
        std.log.scoped(.cache).warn("Cannot write invalid field: `{s}`", .{formatted_key});
        return false;
    }

    /// The caller should `free()` memory the returns value
    pub fn read(self: Cache, alloc: std.mem.Allocator, key: []const u8) ![]const u8 {
        const formatted_key = try std.fmt.allocPrint(alloc, "{s}_{s}", .{ self._prefix, key });
        defer alloc.free(formatted_key);
        const file = try std.fs.openFileAbsolute(self.path, .{ .mode = .read_write });
        defer file.close();
        const content = try file.readToEndAlloc(alloc, 1024); // 1mb
        defer alloc.free(content);

        const parsed: std.json.Parsed(CacheFields) = try std.json.parseFromSlice(
            CacheFields,
            alloc,
            content,
            .{
                .ignore_unknown_fields = true,
                .duplicate_field_behavior = .use_last,
            },
        );
        defer parsed.deinit();
        const v = parsed.value;

        inline for (std.meta.fields(CacheFields)) |f| {
            if (std.mem.eql(u8, f.name, formatted_key)) {
                return alloc.dupe(u8, @field(v, f.name).?);
            }
        }

        std.log.scoped(.cache).warn("Cannot read invalid field: `{s}`", .{formatted_key});
        return error.InvalidField;
    }

    fn checkFieldExists(
        self: Cache,
        alloc: std.mem.Allocator,
        field_name: []const u8,
    ) !bool {
        const formatted_field = try std.fmt.allocPrint(alloc, "{s}_{s}", .{ self._prefix, field_name });
        defer alloc.free(formatted_field);

        inline for (std.meta.fields(CacheFields)) |f| {
            if (std.mem.eql(u8, f.name, formatted_field)) return true;
        }
        return false;
    }
};
