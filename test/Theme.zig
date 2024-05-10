const std = @import("std");
const pal = @import("pal");

pub const Color = union(enum) {
    black,
    red,
    green,
    yellow,
    blue,
    magenta,
    cyan,
    white,
    bright_black,
    bright_red,
    bright_green,
    bright_yellow,
    bright_blue,
    bright_magenta,
    bright_cyan,
    bright_white,

    ansi256: u8,
    rgb: [3]u8,
};

background: ?Color,
foreground: Color,

const Theme = @This();
pub const default = pal.embed(Theme, @embedFile("theme.conf"));

const testing = std.testing;
test Theme {
    try testing.expectEqual(Color.bright_black, default.background.?);
    try testing.expectEqual(42, default.foreground.rgb[0]);
    try testing.expectEqual(76, default.foreground.rgb[1]);
    try testing.expectEqual(97, default.foreground.rgb[2]);

    var context = try pal.string(Theme, @embedFile("theme.override.conf"), testing.allocator);
    defer context.deinit();
    const override = context.instance;
    try testing.expect(Color.bright_black == override.background.?);
    try testing.expect(Color.white == override.foreground);
}
