const std = @import("std");

test "realworld" {
    const tests: []const type = &.{
        @import("Theme.zig"),
        @import("NotVim.zig"),
    };
    inline for (tests) |name| {
        std.testing.refAllDecls(name);
    }
}
