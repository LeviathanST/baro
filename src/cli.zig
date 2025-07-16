const std = @import("std");
const log = std.log;
const Config = @import("Config.zig");

const zigc = @import("zigc.zig");

pub const Arg = struct {
    name: []const u8,
    value: ?[]const u8 = null,

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
    error_data: struct {
        string: []const u8 = "",
    },

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
            .error_data = .{},
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
        if (self.command_table.get(arg.name)) |command| {
            command.execFn(self, self.allocator, arg) catch |err| {
                self.processError(err);
            };
        } else {
            self.error_data.string = arg.name;
            self.processError(error.UnknownCommand);
        }
    }

    pub fn processError(self: Runner, err: anyerror) void {
        switch (err) {
            error.UnknownCommand => log.err("unknown command `{s}`", .{self.error_data.string}),
            error.MissingCommand => log.err("missing command", .{}),
            error.FetchingFailed => std.log.err("fetching {s} failed", .{self.error_data.string}),
            error.NotFound => std.log.err("`{s}` not found", .{self.error_data.string}),
            else => {
                log.debug("unknown error: {}", .{err});
                log.err("unknown error", .{});
            },
        }
    }
};
