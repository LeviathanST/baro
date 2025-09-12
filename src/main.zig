const std = @import("std");
const cli = @import("cli.zig");
const utils = @import("utils.zig");
const Zigc = @import("Zigc.zig");
const Config = @import("Config.zig");

const Color = struct {
    const ESCAPE = "\x1b[";
    pub const RESET = ESCAPE ++ "0m";

    pub const RED_BOLD = ESCAPE ++ "1;31m";
    pub const GREEN_BOLD = ESCAPE ++ "1;32m";
    pub const YELLOW_BOLD = ESCAPE ++ "1;33m";
    pub const PURPLE_BOLD = ESCAPE ++ "1;35m";
};

pub const std_options: std.Options = .{
    .logFn = logFn,
};

fn logFn(
    comptime message_level: std.log.Level,
    comptime scope: @TypeOf(.enum_literal),
    comptime fmt: []const u8,
    args: anytype,
) void {
    if (@intFromEnum(std.options.log_level) < @intFromEnum(message_level))
        return;

    const level, const color = switch (message_level) {
        .debug => .{ "DEBUG", Color.PURPLE_BOLD },
        .err => .{ "ERROR", Color.RED_BOLD },
        .info => .{ "INFO", Color.GREEN_BOLD },
        .warn => .{ "WARNING", Color.YELLOW_BOLD },
    };

    var buf: [64]u8 = undefined;
    const stderr = std.debug.lockStderrWriter(&buf);
    defer std.debug.unlockStderrWriter();

    nosuspend stderr.print(color ++ "[" ++ @tagName(scope) ++ "] " ++ level ++ ": " ++ Color.RESET ++ fmt ++ "\r\n", args) catch return;
}

const General = struct {
    zigc: Zigc,
    pub fn install(self: *anyopaque, alloc: std.mem.Allocator, arg: cli.Arg) !void {
        const general: *General = @ptrCast(@alignCast(self));
        if (arg.options.get("compiler")) |_| {
            try Zigc.install(&general.zigc, alloc, arg);
        }
        if (arg.options.get("linter")) |_| {
            std.log.err("todo", .{});
            unreachable;
        }
        if (arg.options.get("lsp")) |_| {
            std.log.err("todo", .{});
            unreachable;
        }
    }
};

pub fn main() !void {
    var base_alloc, const is_debug = switch (@import("builtin").mode) {
        .Debug => .{ std.heap.DebugAllocator(.{}).init, true },
        else => .{ std.heap.ArenaAllocator.init(std.heap.page_allocator), false },
    };
    defer {
        if (is_debug) {
            const check = base_alloc.deinit();
            if (check == .leak) {
                std.log.debug("Memory leak has been detected!", .{});
            }
        } else {
            base_alloc.deinit();
        }
    }
    const alloc = base_alloc.allocator();

    var config = try Config.init(alloc);
    defer config.deinit();
    var runner: cli.Runner = try .init(alloc, config);

    var zigc = runner.createTool(Zigc, "zigc");
    var general: General = .{ .zigc = zigc };

    try zigc.checkForUpdate(alloc);

    const commands = &[_]cli.Command{
        .{
            .name = "install",
            .exec = .{
                .handle = &general,
                .@"fn" = General.install,
            },
            .take_value = .one,
            .options = &.{
                .{
                    .long_name = "compiler",
                    .short_name = "c",
                    .take_value = .none,
                },
            },
        },
        .{
            .name = "use",
            .exec = .{ .handle = &zigc, .@"fn" = Zigc.use },
            .take_value = .one,
        },
        .{
            .name = "clean",
            .exec = .{ .handle = &zigc, .@"fn" = Zigc.clean },
            .take_value = .one,
        },
        .{ .name = "list", .exec = .{ .handle = &zigc, .@"fn" = Zigc.listAllInstalledVersions } },
        .{ .name = "lista", .exec = .{ .handle = &zigc, .@"fn" = Zigc.listAllAvailableVersions } },
        .{ .name = "update", .exec = .{ .handle = &zigc, .@"fn" = Zigc.update } },
        .{ .name = "config", .exec = .{ .handle = &config, .@"fn" = Config.print } },
    };

    try runner.run(commands);
}
