const std = @import("std");
const log = std.log;
const Config = @import("Config.zig");

const zigc = @import("zigc.zig");

pub const Arg = struct {
    name: []const u8,
    value: ?[]const u8 = null,
    // TODO: options

    /// Take an `Arg` from `std.process.ArgIterator`.
    pub fn fromIter(iter: *std.process.ArgIterator) ?Arg {
        _ = iter.skip(); // skip the program binary
        if (iter.next()) |it| {
            return .{
                .name = it,
                .value = iter.next(),
            };
        } else {
            return null;
        }
    }
};

pub const Command = struct {
    name: []const u8,
    execFn: *const fn (*Runner, std.mem.Allocator, Arg) anyerror!void,
};

pub const Runner = struct {
    allocator: std.mem.Allocator,
    command_table: std.StringHashMap(Command),
    config: Config,
    error_data: ?Error = null,

    pub const Error = union(enum) {
        string: []const u8,
        allocated_string: []const u8,
    };

    pub fn init(alloc: std.mem.Allocator, commands: []const Command) !Runner {
        var table = std.StringHashMap(Command).init(alloc);
        errdefer table.deinit();

        for (commands) |c| {
            try table.put(c.name, c);
        }
        return .{
            .allocator = alloc,
            .command_table = table,
            .config = try .init(alloc),
        };
    }
    pub fn deinit(self: *Runner) void {
        self.command_table.deinit();
        self.config.deinit();
    }

    pub fn run(self: *Runner) !void {
        var argv = try std.process.argsWithAllocator(self.allocator);
        const arg = Arg.fromIter(&argv) orelse {
            self.processError(error.MissingCommand);
            return;
        };
        if (self.config.options.check_for_update.? and !std.mem.eql(u8, arg.name, "update")) {
            if (self.config.options.zigc.check_for_update.?) {
                try zigc.checkForUpdate(self, self.allocator);
            }
        }
        if (self.command_table.get(arg.name)) |command| {
            command.execFn(self, self.allocator, arg) catch |err| {
                self.processError(err);
            };
        } else {
            self.error_data = .{ .string = arg.name };
            self.processError(error.UnknownCommand);
        }
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
