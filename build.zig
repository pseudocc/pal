const std = @import("std");

pub fn build(b: *std.Build) void {
    const pal = b.addModule("pal", .{
        .root_source_file = b.path("lib.zig"),
    });

    const test_step = b.step("test", "Run unit tests");

    const lib_unit_tests = b.addTest(.{
        .name = "lib unit tests",
        .root_source_file = b.path("lib.zig"),
    });
    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);
    test_step.dependOn(&run_lib_unit_tests.step);

    const real_life_tests = b.addTest(.{
        .name = "real_life tests",
        .root_source_file = b.path("test/root.zig"),
    });
    real_life_tests.root_module.addImport("pal", pal);
    const run_real_life_tests = b.addRunArtifact(real_life_tests);
    run_real_life_tests.setCwd(b.path("test"));
    test_step.dependOn(&run_real_life_tests.step);
}
