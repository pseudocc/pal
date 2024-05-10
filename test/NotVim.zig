const std = @import("std");
const pal = @import("pal");

const Theme = @import("Theme.zig");
const Switch = enum { off, on };

smarttab: Switch,
expandtab: Switch,
tabstop: u8,
softtabstop: u8,
shiftwidth: u8,

background: ?Theme.Color,
foreground: Theme.Color,
err: Theme.Color,
warn: Theme.Color = .yellow,
info: Theme.Color = .magenta,

pub const default = pal.embed(@This(), @embedFile("notvim.conf"));

const testing = std.testing;
test default {
    try testing.expectEqual(Switch.off, default.smarttab);
    try testing.expectEqual(Switch.on, default.expandtab);
    try testing.expectEqual(4, default.tabstop);
    try testing.expectEqual(8, default.softtabstop);
    try testing.expectEqual(4, default.shiftwidth);
    try testing.expectEqual(null, default.background);
    try testing.expectEqual(Theme.Color.white, default.foreground);
    try testing.expectEqual(Theme.Color.red, default.err);
    try testing.expectEqual(Theme.Color.yellow, default.warn); // defined in zig code
    try testing.expectEqual(Theme.Color.cyan, default.info);
}
