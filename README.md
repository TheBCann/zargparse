# zargparse.zig

A comptime argument parser for Zig 0.16. Define your CLI args as data, get a typed struct back — no hashmaps, no allocations, no runtime overhead.

```zig
const App = zargparse.Parser("hello", "Greet someone.", &.{
    .{ .name = "name", .positional = true, .required = true, .help = "Who to greet" },
    .{ .name = "shout", .short = 's', .flag = true, .type = .boolean, .help = "SHOUT" },
    .{ .name = "repeat", .short = 'n', .type = .int, .default = "1", .help = "Repeat N times" },
});

const opts = App.parse(raw, io) catch |err| {
    if (err == error.HelpRequested) return;
    std.process.exit(1);
};

opts.name    // []const u8 — required positional, never null
opts.shout   // bool — flag, defaults to false
opts.repeat  // ?i64 — optional int, defaults to 1
```

The compiler generates a unique `Result` struct with real typed fields. No `?[]const u8` dictionary lookups.

## Requirements

Zig **0.16.0-dev** (nightly). Uses `@Struct`, `std.process.Init`, and `std.Io` — none of which exist in 0.13 or 0.14.

## Usage

Add `src/zargparse.zig` to your project and import it:

```zig
const zargparse = @import("argparse.zig");
```

### Defining arguments

Every argument is an `Arg` struct with sensible defaults:

```zig
const App = zargparse.Parser("mytool", "Description shown in --help.", &.{
    // Positional: no dashes, matched by order
    .{ .name = "input", .positional = true, .required = true, .help = "Input file" },

    // Option: --output FILE or -o FILE
    .{ .name = "output", .short = 'o', .help = "Output file" },

    // Flag: --verbose or -v, no value consumed
    .{ .name = "verbose", .short = 'v', .flag = true, .type = .boolean, .help = "Verbose output" },

    // Count: -vvv accumulates to 3
    .{ .name = "debug", .short = 'd', .flag = true, .type = .count, .help = "Debug level" },

    // Int with default
    .{ .name = "jobs", .short = 'j', .type = .int, .default = "4", .help = "Parallel jobs" },

    // Choices: validated at runtime, shown in --help
    .{ .name = "format", .short = 'f', .choices = &.{ "json", "csv", "xml" }, .default = "json" },
});
```

### Parsing

```zig
pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const raw = try init.minimal.args.toSlice(init.arena.allocator());

    // parse() prints colored errors to stderr and --help to stdout
    const opts = App.parse(raw, io) catch |err| {
        if (err == error.HelpRequested) return;
        std.process.exit(1);
    };

    // Use opts.input, opts.output, opts.verbose, etc.
}
```

For tests or programmatic use, `parseRaw` skips all I/O:

```zig
const opts = try App.parseRaw(&argv);
```

### Auto-generated help

```
Usage: mytool [--output <OUTPUT>] [--verbose] [--jobs <JOBS>] <input>

Description shown in --help.

Positional arguments:
  input                    Input file

Options:
  -h, --help               Show this help message
  -o, --output <OUTPUT> Output file
  -v, --verbose         Verbose output
  -d, --debug           Debug level
  -j, --jobs <JOBS>     Parallel jobs (default: 4)
  -f, --format <FORMAT> (default: json) {json, csv, xml}
```

## Type mapping

| Arg config                             | Result field type |
| -------------------------------------- | ----------------- |
| `.positional = true, .required = true` | `[]const u8`      |
| `.positional = true` (optional)        | `?[]const u8`     |
| `.required = true`                     | `[]const u8`      |
| optional (default)                     | `?[]const u8`     |
| `.flag = true, .type = .boolean`       | `bool`            |
| `.flag = true, .type = .count`         | `usize`           |
| `.type = .int`                         | `?i64` or `i64`   |
| `.type = .float`                       | `?f64` or `f64`   |

Required and positional-required fields are non-nullable. Everything else is optional (`?T`) with a default of `null` unless `.default` is set.

## Parsing behavior

**Long options:** `--output file.txt`, `--output=file.txt`

**Short options:** `-o file.txt`, `-ofile.txt`

**Stacked short flags:** `-vvv` (count = 3), `-vn 5` (verbose + repeat=5), `-voout.txt` (verbose + output=out.txt)

**Positionals:** matched in declaration order. `mytool input.txt output.txt`

**Double dash:** `--` stops option parsing. `mytool -- --not-a-flag` treats `--not-a-flag` as a positional.

**Booleans:** `--flag true`, `--flag false`, `--flag yes`, `--flag no`, `--flag 1`, `--flag 0`

## Comptime validation

Invalid argument definitions are caught at compile time:

```zig
// error: positional cannot be a flag
.{ .name = "x", .positional = true, .flag = true }

// error: flags must be boolean or count type
.{ .name = "x", .flag = true, .type = .string }

// error: required positional after optional positional
.{ .name = "a", .positional = true },
.{ .name = "b", .positional = true, .required = true },

// error: invalid default int
.{ .name = "x", .type = .int, .default = "abc" }

// error: multi-value args not yet supported
.{ .name = "x", .multi = true }
```

## Errors

| Error                  | Cause                                      |
| ---------------------- | ------------------------------------------ |
| `HelpRequested`        | User passed `--help` or `-h`               |
| `UnknownOption`        | Unrecognized `--flag` or `-x`              |
| `MissingValue`         | Option expects a value but none given      |
| `MissingRequired`      | Required argument not provided             |
| `InvalidValue`         | Value can't be parsed as the expected type |
| `InvalidChoice`        | Value not in the `.choices` list           |
| `UnexpectedPositional` | Too many positional arguments              |

## Tests

```sh
zig test src/zargparse.zig
```

29 tests covering positionals, long/short options, stacked flags, count accumulation, choices, defaults, `--` separator, error cases, and comptime type generation.

## Examples

```sh
# Minimal greeter
zig run examples/example_minimal.zig -- world
zig run examples/example_minimal.zig -- --shout -n 3 world

# HTTP client options demo
zig run examples/example_fetch.zig -- https://example.com
zig run examples/example_fetch.zig -- -vvv -X POST --format json https://example.com
zig run examples/example_fetch.zig -- --help
```

## License

MIT
