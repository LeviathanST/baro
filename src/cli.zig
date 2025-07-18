const std = @import("std");
const log = std.log;
const Config = @import("Config.zig");

const zigc = @import("zigc.zig");

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
    options: []const Option,
    take_value: TakeValue = .none,
    execFn: *const fn (*Runner, std.mem.Allocator, Arg) anyerror!void,

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

        /// Get a generic name `(currently, always long name)`
        /// from a long or short name
        pub fn getGenericName(opt: Option, short_or_long_name: []const u8) []const u8 {
            if (opt.eqlName(short_or_long_name)) {
                return opt.long_name;
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

    pub fn init(alloc: std.mem.Allocator) !Runner {
        return .{
            .allocator = alloc,
            .config = try .init(alloc),
        };
    }
    pub fn deinit(self: *Runner) void {
        self.config.deinit();
    }

    pub fn run(self: *Runner, comptime commands: []const Command) !void {
        var argv = try std.process.argsWithAllocator(self.allocator);
        _ = argv.skip();
        const command = argv.next() orelse {
            self.error_data = .{ .string = "" };
            return self.processError(error.MissingCommand);
        };
        if (self.config.options.check_for_update.? and !std.mem.eql(u8, command, "update")) {
            if (self.config.options.zigc.check_for_update.?) {
                try zigc.checkForUpdate(self, self.allocator);
            }
        }
        inline for (commands) |c| {
            if (std.mem.eql(u8, c.name, command)) {
                var arg = self.parseArg(c, &argv) catch |err| {
                    return self.processError(err);
                };
                defer arg.deinit();
                return c.execFn(self, self.allocator, arg) catch |err| {
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
        comptime command: Command,
        iter: *std.process.ArgIterator,
    ) !Arg {
        var options = std.StringHashMap(Arg.Option).init(self.allocator);
        while (iter.next()) |it| {
            if (std.mem.startsWith(u8, it, "-")) {
                const option = try self.parseOption(command.options, iter, it);
                try options.put(it, option);
            }
        }

        var arg: Arg = .{
            .options = options,
        };
        errdefer arg.deinit();

        if (command.take_value != .none) {
            if (iter.next()) |value| {
                arg.value = value;
            } else {
                self.error_data = .{ .string = command.name };
                return error.MissingValue;
            }
        }
        return arg;
    }

    fn parseOption(
        self: *Runner,
        comptime opts: []const Command.Option,
        iter: *std.process.ArgIterator,
        s: []const u8,
    ) !Arg.Option {
        inline for (opts) |opt| {
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
            else => {
                log.debug("unknown error: {}", .{err});
                log.err("unknown error", .{});
            },
        }
    }
};
