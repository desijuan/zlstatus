const std = @import("std");

const OutMode = enum { X11, Wayland };

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    const out_mode: OutMode = b.option(OutMode, "mode", "X11 or Wayland") orelse .Wayland;

    const options = b.addOptions();
    options.addOption(OutMode, "out_mode", out_mode);
    mod.addOptions("config", options);

    if (out_mode == .X11) mod.linkSystemLibrary("X11", .{});
    mod.linkSystemLibrary("asound", .{});

    const exe = b.addExecutable(.{
        .name = "zlstatus",
        .root_module = mod,
    });

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const unit_tests = b.addTest(.{
        .root_module = mod,
    });

    const run_unit_tests = b.addRunArtifact(unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
}
