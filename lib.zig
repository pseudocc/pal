const std = @import("std");
const testing = std.testing;

const Type = std.builtin.Type;
const Dir = std.fs.Dir;
const Allocator = std.mem.Allocator;
const global = @This();

pub const WhiteSpaces = " \t";
pub const NewLines = "\r\n";

const ParseFloatError = std.fmt.ParseFloatError;
const ParseIntError = std.fmt.ParseIntError || error{
    InvalidBase,
};
const ParseBoolError = error{
    InvalidBoolean,
};
const ParseEnumError = error{
    InvalidVariant,
};
const ParseTaggedUnionError = ParseEnumError || error{
    UnclosedParenthesis,
};
const ParseStructError = error{
    UnexpectedPattern,
    InvalidField,
    MissingRequiredField,
};
pub const ParseError = ParseFloatError || ParseIntError || ParseBoolError || ParseEnumError || ParseTaggedUnionError || ParseStructError || Allocator.Error || Dir.OpenError;

const RawArrayIterator = struct {
    const delimiter = ',';
    const escape = '\\';
    const Self = @This();

    index: usize = 0,
    buffer: []const u8,

    pub fn nextIndex(self: *Self) ?usize {
        if (self.index >= self.buffer.len) return null;

        var i = self.index;
        var unclosed: usize = 0;
        defer self.index = i + 1;

        while (i < self.buffer.len) : (i += 1) {
            switch (self.buffer[i]) {
                '(' => unclosed += 1,
                ')' => unclosed -= 1,
                ',' => if (unclosed == 0) {
                    const lastc = if (i > 0) self.buffer[i - 1] else 0;
                    if (lastc == escape) continue;
                    return i;
                },
                else => {},
            }
        }

        return self.buffer.len;
    }

    pub fn next(self: *Self) ?[]const u8 {
        const i = self.index;
        const nexti = self.nextIndex() orelse return null;
        return self.buffer[i..nexti];
    }

    pub fn count(self: *Self) usize {
        var n_items: usize = 0;
        const i = self.index;
        defer self.index = i;
        while (self.nextIndex()) |_| : (n_items += 1) {}
        return n_items;
    }

    pub inline fn reset(self: *Self) void {
        self.index = 0;
    }

    pub fn tryEscape(raw: []const u8, allocator: Allocator) ![]const u8 {
        var lastc: u8 = 0;
        var buffer: []u8 = if (@inComptime()) z: {
            var escaped: [raw.len]u8 = undefined;
            break :z &escaped;
        } else try allocator.alloc(u8, raw.len);
        var i: usize = 0;

        defer if (!@inComptime()) {
            _ = allocator.resize(buffer, i);
        };

        for (raw) |c| {
            if (lastc == escape) {
                if (c == escape or c == delimiter) {
                    buffer[i] = c;
                    i += 1;
                } else {
                    buffer[i] = escape;
                    i += 1;
                    buffer[i] = c;
                    i += 1;
                }

                lastc = 0;
                continue;
            } else if (c != escape) {
                buffer[i] = c;
                i += 1;
            }
            lastc = c;
        }

        return buffer[0..i];
    }
};

/// std.mem.splitSequence(u8, raw, ",") won't work in our case because we need
/// to handle nested inputs for tagged union slices, like:
/// ```zig
/// const Token = union(enum) {
///     int: i64,
///     add: [2]i64,
/// };
/// const tokens = try parse([]Token, "int(42),add(1,2)", allocator);
/// ```
pub inline fn splitRawArray(raw: []const u8) RawArrayIterator {
    return .{ .buffer = raw };
}

test RawArrayIterator {
    comptime {
        var it = splitRawArray("a,b,c");
        try testing.expectEqual(it.index, 0);

        for (&.{ "a", "b", "c" }) |expected| {
            const item = it.next();
            try testing.expectEqualStrings(expected, item.?);
        }

        const none = it.next();
        try testing.expectEqual(null, none);

        it.reset();
        try testing.expectEqual(it.index, 0);
    }

    var it = splitRawArray("add(1,2),int(42),pow(2,3)");
    inline for (&.{ "add(1,2)", "int(42)", "pow(2,3)" }) |expected| {
        const item = it.next();
        try testing.expectEqualStrings(expected, item.?);
    }
}

test "RawArrayIterator.tryEscape" {
    const tryEscape = RawArrayIterator.tryEscape;
    const TestCase = struct {
        raw: []const u8,
        escaped: []const u8,
    };

    const cases: []const TestCase = &.{
        .{ .raw = "", .escaped = "" },
        .{ .raw = "a", .escaped = "a" },
        .{ .raw = "a,b", .escaped = "a,b" },
        .{ .raw = "a\\,b", .escaped = "a,b" },
        .{ .raw = "a\\\\b", .escaped = "a\\b" },
        .{ .raw = "a\\\\,b", .escaped = "a\\,b" },
        .{ .raw = "a\\,\\,b", .escaped = "a,,b" },
        .{ .raw = "a\\,\\,b\\,c", .escaped = "a,,b,c" },
    };

    comptime {
        for (cases) |c| {
            const escaped = try tryEscape(c.raw, undefined);
            try testing.expectEqualStrings(c.escaped, escaped);
        }
    }

    const allocator = testing.allocator;
    for (cases) |c| {
        const escaped = try tryEscape(c.raw, allocator);
        defer allocator.free(escaped);
        try testing.expectEqualStrings(c.escaped, escaped);
    }
}

/// Parse a raw string into a value of type `T`.
/// `raw`: the trimmed raw string to be parsed.
/// `allocator`: will not be used at comptime, feel free to pass `undefined`.
pub fn parse(comptime T: type, raw: []const u8, allocator: Allocator) ParseError!T {
    if (T == []const u8) {
        if (@inComptime()) return raw;
        return try allocator.dupe(u8, raw);
    }
    if (T == Dir)
        return try std.fs.cwd().openDir(raw, .{});
    switch (@typeInfo(T)) {
        .Optional => |opt| {
            if (std.mem.eql(u8, raw, "none")) return null;
            return try parse(opt.child, raw, allocator);
        },
        .Struct => {
            if (!@hasDecl(T, "parse")) {
                @compileError("Struct " ++ @typeName(T) ++ " does not have a parse method");
            }
            const parse_fn: fn ([]const u8, Allocator) ParseError!T = @field(T, "parse");
            return try parse_fn(raw, allocator);
        },
        .Bool => {
            if (std.mem.eql(u8, raw, "true")) return true;
            if (std.mem.eql(u8, raw, "false")) return false;
            return ParseBoolError.InvalidBoolean;
        },
        .Float => return try std.fmt.parseFloat(T, raw),
        .Int => {
            const base: u8 = if (raw.len > 2 and raw[0] == '0') z: {
                break :z switch (std.ascii.toLower(raw[1])) {
                    'b' => 2,
                    'o' => 8,
                    'x' => 16,
                    else => return ParseIntError.InvalidBase,
                };
            } else return std.fmt.parseInt(T, raw, 10);
            return std.fmt.parseInt(T, raw[2..], base);
        },
        .Enum => return std.meta.stringToEnum(T, raw) orelse ParseEnumError.InvalidVariant,
        .Union => |uni| if (uni.tag_type) |_| {
            var i: usize = 0;
            var j = std.mem.indexOf(u8, raw, "(") orelse raw.len;
            const tag = std.mem.trimRight(u8, raw[0..j], WhiteSpaces);

            i = j + 1;
            j = std.mem.lastIndexOf(u8, raw, ")") orelse 0;

            inline for (uni.fields) |field| {
                if (std.mem.eql(u8, field.name, tag)) {
                    if (field.type == void) return @unionInit(T, field.name, {});

                    if (i >= j) return ParseTaggedUnionError.UnclosedParenthesis;
                    const inner_raw = std.mem.trim(u8, raw[i..j], WhiteSpaces);
                    const inner_value = try parse(field.type, inner_raw, allocator);
                    return @unionInit(T, field.name, inner_value);
                }
            }

            return ParseTaggedUnionError.InvalidVariant;
        } else @compileError("Untagged union is not supported"),
        .Array => |arr| {
            var container: T = std.mem.zeroes(T);
            try parseSlices(arr.child, raw, &container, allocator);
            return container;
        },
        .Pointer => |ptr| {
            if (raw.len == 0) {
                // copied from std.mem
                const p = std.mem.alignBackward(usize, std.math.maxInt(usize), ptr.alignment);
                return @as([*]align(ptr.alignment) ptr.child, @ptrFromInt(p))[0..0];
            }

            var lines = splitRawArray(raw);
            const n_items = lines.count();

            const container: []ptr.child = if (@inComptime()) z: {
                var items: [n_items]ptr.child = undefined;
                break :z &items;
            } else try allocator.alloc(ptr.child, n_items);

            try parseSlices(ptr.child, raw, container, allocator);
            if (@inComptime()) {
                const final = container[0..n_items].*;
                return &final;
            }
            return @as(T, @ptrCast(container));
        },
        else => @compileError("Unsupported type: " ++ @typeName(T)),
    }
}

fn parseSlices(comptime T: type, raw: []const u8, container: []T, allocator: Allocator) !void {
    var raw_items = splitRawArray(raw);
    var i: usize = 0;

    while (raw_items.next()) |item| : (i += 1) {
        const trimmed_item = std.mem.trim(u8, item, WhiteSpaces);
        const escaped_item = try RawArrayIterator.tryEscape(trimmed_item, allocator);
        defer if (!@inComptime()) allocator.free(escaped_item);
        container[i] = try parse(T, escaped_item, allocator);
    }
}

/// Parse a struct from a multiline input.
/// ```
/// license     mit
/// version     0.1.0
/// authors     pseudoc, pseudocc
/// ```
/// If your field is a struct, you need to implement a `parse` method and
/// optionally a `free` method.
/// ```zig
/// pub fn parse(raw: []const u8, allocator: Allocator) ParseError!Self()
/// pub fn free(instance: Self, allocator: Allocator) void
/// ```
pub fn ParseContext(comptime T: type) type {
    const ArenaAllocator = std.heap.ArenaAllocator;
    const logger = std.log.scoped(.pal);

    const Keywords = enum { include, config_dir };
    const type_info: Type.Struct = switch (@typeInfo(T)) {
        .Struct => |info| info,
        else => @compileError("Struct type expected"),
    };

    return struct {
        const Self = @This();

        arena: ArenaAllocator,
        instance: T,
        config_dir: Dir,

        pub fn init(allocator: Allocator) Self {
            return .{
                .arena = ArenaAllocator.init(allocator),
                .instance = comptime default_instance(),
                .config_dir = std.fs.cwd(),
            };
        }

        pub fn deinit(self: Self) void {
            self.arena.deinit();
        }

        fn default_instance() T {
            var instance: T = undefined;
            for (type_info.fields) |field| {
                if (field.default_value) |opaque_ptr| {
                    const default_value: *const field.type = @ptrCast(@alignCast(opaque_ptr));
                    @field(instance, field.name) = default_value.*;
                } else if (@typeInfo(field.type) == .Optional) {
                    @field(instance, field.name) = null;
                }
            }
            return instance;
        }

        fn auto_fields() []Type.StructField {
            var values: [type_info.fields.len]Type.StructField = undefined;
            var i: usize = 0;
            for (type_info.fields) |field| {
                for (std.meta.fieldNames(Keywords)) |keyword| {
                    if (std.mem.eql(u8, field.name, keyword))
                        @compileError("Field name is a keyword: " ++ field.name);
                }

                if (field.name[0] == '_' or field.is_comptime)
                    continue;
                values[i] = field;
                i += 1;
            }
            return values[0..i];
        }

        pub fn line(self: *Self, raw: []const u8) ParseFileError!void {
            const trimmed = std.mem.trim(u8, raw, WhiteSpaces);
            if (trimmed.len == 0 or trimmed[0] == '#')
                return;

            const i = std.mem.indexOfAny(u8, trimmed, WhiteSpaces) orelse trimmed.len;
            const field_name = trimmed[0..i];
            const raw_value = std.mem.trim(u8, trimmed[i..], WhiteSpaces);
            const allocator = if (@inComptime()) undefined else self.arena.allocator();

            if (std.mem.eql(u8, field_name, "config_dir")) {
                self.config_dir = try parse(Dir, raw_value, undefined);
                return;
            }

            if (std.mem.eql(u8, field_name, "include")) {
                try self.file(raw_value);
                return;
            }

            inline for (comptime auto_fields()) |field| {
                if (std.mem.eql(u8, field.name, field_name)) {
                    const value = try parse(field.type, raw_value, allocator);
                    @field(self.instance, field.name) = value;
                    return;
                }
            }
        }

        pub fn string(self: *Self, raw: []const u8) ParseFileError!void {
            var lines = std.mem.tokenizeAny(u8, raw, NewLines);
            while (lines.next()) |raw_line| {
                try self.line(raw_line);
            }
        }

        fn part(self: *Self, raw: []const u8, linenum: *usize) ParseFileError!void {
            var lines = std.mem.tokenizeAny(u8, raw, NewLines);
            while (lines.next()) |raw_line| : (linenum.* += 1) {
                self.line(raw_line) catch |e| {
                    logger.err("Error at line {d}: \"{s}\"", .{ linenum, raw_line });
                    return e;
                };
            }
        }

        const File = std.fs.File;
        const ParseFileError = File.OpenError || File.ReadError || ParseError || error{LineTooLong};
        pub fn file(self: *Self, path: []const u8) ParseFileError!void {
            const BUF_SIZE = 4096;
            var f = try self.config_dir.openFile(path, .{});
            var buf: [BUF_SIZE]u8 = undefined;
            var offset: usize = 0;
            var linenum: usize = 1;

            defer f.close();
            while (true) {
                const bytes_read = try f.read(buf[offset..]);
                const end = offset + bytes_read;
                const maybe_lastnl = std.mem.lastIndexOfAny(u8, buf[0..end], NewLines);

                if (maybe_lastnl) |lastnl| {
                    const processed = lastnl + 1;
                    try self.part(buf[0..processed], &linenum);
                    const unused = end - processed;
                    if (unused > 0)
                        @memcpy(buf[0..unused], buf[processed..end]);
                    offset = unused;
                } else if (end == BUF_SIZE) {
                    logger.err("Line too long at line {d}: \"{s}\"", .{ linenum, buf[0..80] });
                    return ParseFileError.LineTooLong;
                } else if (bytes_read == 0) {
                    try self.part(buf[0..end], &linenum);
                    break;
                }
            }
        }
    };
}

/// Read a multiline input and parse it into a struct instance.
pub fn string(comptime T: type, raw: []const u8, allocator: Allocator) !ParseContext(T) {
    var context = ParseContext(T).init(allocator);
    errdefer context.deinit();

    try context.string(raw);
    return context;
}

/// Read a multiline input and parse it into a struct instance at
/// comptime.
/// Example:
/// ```zig
/// pub const default = embed(Config, @embedFile("foo.conf"));
/// pub const default = embed(Config,
///    \\stay_hungry true
///    \\stay_foolish true
/// );
pub fn embed(comptime T: type, comptime raw: []const u8) T {
    @setEvalBranchQuota(ParseContext(T).auto_fields().len * 1000);
    const context = string(T, raw, undefined) catch @panic("Parse failed");
    return context.instance;
}

test parse {
    const E = enum { a, b };
    const U = union(enum) { c: u8, d, e: E };

    comptime {
        const allocator: Allocator = undefined;

        const a = try parse(E, "a", allocator);
        try testing.expectEqual(E.a, a);

        const uc = try parse(U, "c(42)", allocator);
        try testing.expectEqual(U{ .c = 42 }, uc);

        const ud = try parse(U, "d", allocator);
        try testing.expectEqual(U.d, ud);

        const ue = try parse(U, "e(b)", allocator);
        try testing.expectEqual(U{ .e = E.b }, ue);

        const int2 = try parse([2]u8, "1,2", allocator);
        try testing.expectEqualSlices(u8, &.{ 1, 2 }, &int2);
    }

    const allocator = testing.allocator;

    const first3_primes = try parse([]u8, "2,3,5", allocator);
    defer allocator.free(first3_primes);
    try testing.expectEqualSlices(u8, &.{ 2, 3, 5 }, first3_primes);

    const eab = try parse([]E, "a,b", allocator);
    defer allocator.free(eab);
    try testing.expectEqualSlices(E, &.{ E.a, E.b }, eab);
}

test ParseContext {
    const Switch = enum {
        off,
        on,
    };

    const Difficulty = enum {
        easy,
        normal,
        hard,
    };

    const Mode = union(enum) {
        time: u64,
        score: u32,
        zen,
    };

    const Point = struct {
        x: u8,
        y: u8,

        pub fn parse(raw: []const u8, allocator: Allocator) !@This() {
            if (raw.len == 0) return ParseStructError.MissingRequiredField;
            if (raw.len <= 2 or raw[0] != '(' or raw[raw.len - 1] != ')')
                return ParseStructError.UnexpectedPattern;
            const inner_raw = std.mem.trim(u8, raw[1 .. raw.len - 1], WhiteSpaces);
            const values = try global.parse([2]u8, inner_raw, allocator);
            return .{ .x = values[0], .y = values[1] };
        }
    };

    const Config = struct {
        auto_start: Switch,
        auto_exit: ?Switch,
        difficulty: Difficulty,
        description: []const u8,
        magic: u32,
        mode: Mode,
        altmode: ?Mode,
        range: [2]u8,
        coords: []const Point,
        zig_magic: u16 = 65521,
    };

    const context = try string(Config,
        \\# vim: noet:ts=4
        \\auto_start   on
        \\auto_exit    none
        \\
        \\# another comment
        \\difficulty   hard
        \\description  Hello, world!
        \\magic        42
        \\mode         time(1000)
        \\altmode      zen
        \\range        69, 96
        \\coords       (1, 2), (3, 4)
        \\# zig_magic is not in the input
    , testing.allocator);

    defer context.deinit();
    const config = context.instance;
    try testing.expect(Switch.on == config.auto_start);
    try testing.expect(null == config.auto_exit);
    try testing.expect(Difficulty.hard == config.difficulty);
    try testing.expectEqualStrings("Hello, world!", config.description);
    try testing.expect(42 == config.magic);
    try testing.expect(1000 == config.mode.time);
    try testing.expect(Mode.zen == config.altmode.?);
    try testing.expectEqualSlices(u8, &.{ 69, 96 }, &config.range);
    try testing.expect(1 == config.coords[0].x);
    try testing.expect(2 == config.coords[0].y);
    try testing.expect(3 == config.coords[1].x);
    try testing.expect(4 == config.coords[1].y);
    try testing.expect(65521 == config.zig_magic);
}
