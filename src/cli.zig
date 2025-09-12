const std = @import("std");
const log = std.log;
const Config = @import("Config.zig");

const Zigc = @import("Zigc.zig");

pub const Arg = struct {
    /// The command's value
    value: ?[]const u8 = null,
    options: std.StringHashMap(Option),

    pub const Option = struct {
        name: []const u8,
        value: ?[]const u8 = null,
    };

    pub fn deinit(self: *Arg) void {
        self.options.deinit();
    }
};

pub const Command = struct {
    name: []const u8,
    options: []const Option = &.{},
    take_value: TakeValue = .none,
    exec: struct {
        handle: *anyopaque,
        @"fn": *const fn (*anyopaque, std.mem.Allocator, Arg) anyerror!void,
    },

    pub const Option = struct {
        short_name: []const u8,
        long_name: []const u8,
        take_value: TakeValue,

        pub fn eqlName(opt: Option, s: []const u8) bool {
            if (std.mem.startsWith(
                u8,
                s,
                "--",
            )) {
                var split = std.mem.splitSequence(u8, s, "--");
                _ = split.first();
                return std.mem.eql(
                    u8,
                    opt.long_name,
                    split.next().?,
                );
            } else {
                var split = std.mem.splitScalar(u8, s, '-');
                _ = split.first();
                return std.mem.eql(
                    u8,
                    opt.short_name,
                    split.next().?,
                );
            }
        }
    };

    pub const TakeValue = enum {
        none,
        one,
    };
};

pub const Runner = struct {
    allocator: std.mem.Allocator,
    config: Config,
    error_data: ?Error = null,

    pub const Error = union(enum) {
        string: []const u8,
        allocated_string: []const u8,
    };

    pub fn init(alloc: std.mem.Allocator, config: Config) !Runner {
        return .{
            .allocator = alloc,
            .config = config,
        };
    }

    pub fn createTool(
        self: *Runner,
        comptime T: type,
        sub_path: []const u8,
    ) T {
        if (!@hasDecl(T, "init")) {
            const msg = std.fmt.comptimePrint(
                "`{s}` doesn't have `init` function.",
                .{@typeName(T)},
            );
            @compileError(msg);
        }

        return T.init(self, sub_path);
    }

    pub fn run(self: *Runner, commands: []const Command) !void {
        var argv = try std.process.argsWithAllocator(self.allocator);
        _ = argv.skip();
        const command = argv.next() orelse {
            self.error_data = .{ .string = "" };
            return self.processError(error.MissingCommand);
        };

        for (commands) |c| {
            if (std.mem.eql(u8, c.name, command)) {
                var arg = self.parseArg(c, &argv) catch |err| {
                    return self.processError(err);
                };
                defer arg.deinit();

                return c.exec.@"fn"(c.exec.handle, self.allocator, arg) catch |err| {
                    self.processError(err);
                };
            }
        }
        self.error_data = .{ .string = command };
        self.processError(error.UnknownCommand);
    }

    /// Parse an `Arg` from `std.process.ArgIterator`.
    fn parseArg(
        self: *Runner,
        command: Command,
        iter: *std.process.ArgIterator,
    ) !Arg {
        var options = std.StringHashMap(Arg.Option).init(self.allocator);
        errdefer options.deinit();

        while (iter.next()) |it| {
            if (std.mem.startsWith(u8, it, "-")) {
                const option = try self.parseOption(command.options, iter, it);
                try options.put(option.name, option);
            } else {
                if (command.take_value != .none) {
                    return .{
                        .options = options,
                        .value = it,
                    };
                }
            }
        }

        if (command.take_value == .none)
            return .{ .options = options };

        self.error_data = .{ .string = command.name };
        return error.MissingValue;
    }

    fn parseOption(
        self: *Runner,
        opts: []const Command.Option,
        iter: *std.process.ArgIterator,
        s: []const u8,
    ) !Arg.Option {
        for (opts) |opt| {
            if (opt.eqlName(s)) {
                // NOTE: Always assign the long name for a option here.
                var option: Arg.Option = .{ .name = opt.long_name };
                if (opt.take_value != .none) {
                    option.value = iter.next().?;
                }
                log.debug("Using option: {s}", .{s});
                return option;
            }
        }

        self.error_data = .{ .string = s };
        return error.UnknownOption;
    }

    pub fn processError(self: Runner, err: anyerror) void {
        const str, const is_allocated = switch (self.error_data.?) {
            .allocated_string => |slice| .{ slice, true },
            .string => |slice| .{ slice, false },
        };
        defer if (is_allocated) {
            self.allocator.free(str);
        };

        switch (err) {
            error.UnknownCommand => log.err("unknown command `{s}`", .{str}),
            error.UnknownOption => log.err("unknown option `{s}`", .{str}),
            error.MissingCommand => log.err("missing command", .{}),
            error.MissingValue => log.err("missing value for `{s}` command", .{str}),
            error.AccessDenied => log.err(
                \\you need to run this command with sudo
                \\(REASON: {s})
            , .{str}),
            error.FetchingFailed => std.log.err("fetching {s} failed", .{str}),
            error.Unsupported => std.log.err("your cpu arch - os ({s}) is not supported", .{str}),
            error.NotFound => std.log.err("{s} not found", .{str}),
            error.NotInstalled => std.log.err("{s} is not installed", .{str}),
            else => {
                log.debug("unknown error: {}", .{err});
                log.err("unknown error", .{});
            },
        }
    }
};
