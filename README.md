# PAL

`pal` is a zig library that help you to load text configurations.
The configuration format is pretty simple:

```
# the comment
key             value
array           item0, item1, item2
tagged_union0   the_void
tagged_union1   tag(value)
```

The library is designed to be used in zig programs, it is tested on zig 0.12.0.

## Usage

To create a default configuration at `comptime`:
```zig
const pal = @import("pal");
const Config = @This();

const Gender = union(enum) {
  male,
  female,
  other: []const u8,
};

name: []const u8,
gender: Gender,
age: u8,

pub const default = pal.embed(Config,
    \\name      nobody,
    \\gender    other(unknown),
    \\age       0,
);
```
And of course, you can use `@embedFile` to load configurations from a file.

To load a configuration at runtime, you need to take care of the memory:
```zig
var context = pal.string(Config, raw, allocator);
defer context.deinit();
const config = context.instance;

var context = pal.ParseContext(Config).init(allocator);
try context.deinit();
try context.file("/home/user/some.conf");
try context.string("age 1");
```

### Special Keywords

1. `config_dir`: the directory we try to find other configuration via `inlcude`.
default is `std.fs.cwd()`.

2. `include`: you may include other configurations in the configuration file.
Example: see `test/theme.override.conf`

### Type Spec

1. `[]const u8`: will duplicate the raw string and return.
    ```zig
    // description  Better call Saul!
    description: []const u8,
    ```

2. `Enum`: calling `std.meta.stringToEnum` under the hood.
    ```zig
    // os   linux
    os: enum { linux, macos, windows, other },
    ```
3. Tagged `Union`: like `Enum` but inner values are surrounded by `()`.
    ```zig
    // os   linux(ubuntu)
    // os   macos
    // os   windows(11)
    os: union(enum) {
        linux: []const u8,
        macos,
        windows: u8,
    },
    ```

4. `Array`/`Pointer`: split the raw string by `","`, then parse the children.
    ```zig
    // triangle     5,12,13
    triangle: [3]u32,
    // fruits       apple,banana,cherry
    fruits: []const Fruit,
    ```
