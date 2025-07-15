const std = @import("std");

pub fn build(b: *std.Build) void {
    const t = b.standardTargetOptions(.{});
    const o = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "baro",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = t,
            .optimize = o,
        }),
    });
    const known_folders = b.dependency("known_folders", .{}).module("known-folders");
    exe.root_module.addImport("known_folders", known_folders);
    b.installArtifact(exe);
}
