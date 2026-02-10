const std = @import("std");
const Io = std.Io;

// =============================================================================
// Core Types
// =============================================================================

/// Value types for argument parsing. Determines how the string value
/// from the command line is converted and what Zig type the Result field gets.
pub const ArgType = enum {
    /// []const u8 — no conversion, raw string
    string,
    /// i64 — parsed via std.fmt.parseInt
    int,
    /// f64 — parsed via std.fmt.parseFloat
    float,
    /// bool — accepts: true/false, yes/no, 1/0
    boolean,
    /// usize — increments per flag occurrence (-vvv = 3)
    count,
};

pub const Arg = struct {
    /// Long name without dashes: "output" becomes --output.
    /// Also used as the field name in the parsed Result struct.
    name: []const u8,

    /// Single-character short flag: 'o' becomes -o. Supports stacking: -vvv
    short: ?u8 = null,

    /// Description shown in --help output
    help: []const u8 = "",

    /// Value type for parsing. Determines the Result field's Zig type:
    ///   .string  → []const u8
    ///   .int     → i64
    ///   .float   → f64
    ///   .boolean → bool
    ///   .count   → usize (increments per occurrence: -vvv = 3)
    type: ArgType = .string,

    /// If true, parse() returns error.MissingRequired when not provided
    required: bool = false,

    /// Positional argument — no -- prefix needed. Order matters.
    /// First positional definition matches first bare value, etc.
    positional: bool = false,

    /// Default value as a string, parsed at comptime into the correct type.
    /// Examples: "42" for .int, "true" for .boolean, "output.txt" for .string
    default: ?[]const u8 = null,

    /// Presence flag — consumes no value. Field becomes bool (true when present).
    /// Combine with .type = .count for accumulating flags (-vvv).
    flag: bool = false,

    /// Collect multiple values (NOT YET IMPLEMENTED — stores last value only)
    multi: bool = false,

    /// Restrict accepted values. Validated at runtime, shown in --help.
    /// Example: .choices = &.{ "json", "csv", "xml" }
    choices: ?[]const []const u8 = null,

    /// Label shown in help instead of uppercased name: --output <FILE>
    metavar: ?[]const u8 = null,
};

// =============================================================================
// Comptime Result Type Generation
// =============================================================================

/// Given a comptime slice of Arg definitions, generate a struct type
/// where each field corresponds to an argument with the appropriate Zig type.
fn ResultType(comptime args: []const Arg) type {
    var names: [args.len][]const u8 = undefined;
    var types: [args.len]type = undefined;
    var attrs: [args.len]std.builtin.Type.StructField.Attributes = undefined;

    for (args, 0..) |arg, i| {
        names[i] = arg.name;
        types[i] = argZigType(arg);
        attrs[i] = .{};
    }

    return @Struct(.auto, null, &names, &types, &attrs);
}

fn argZigType(comptime arg: Arg) type {
    if (arg.multi) {
        // Multi-value: always a slice of the base type
        const Base = argBaseType(arg);
        return []const Base;
    }
    if (arg.type == .count) return usize; // count before flag — count flags are usize not bool
    if (arg.flag) return bool;

    const Base = argBaseType(arg);
    if (arg.required or arg.positional) return Base;
    return ?Base; // Optional fields are nullable
}

fn argBaseType(comptime arg: Arg) type {
    return switch (arg.type) {
        .string => []const u8,
        .int => i64,
        .float => f64,
        .boolean => bool,
        .count => usize,
    };
}

// =============================================================================
// Parser
// =============================================================================

/// Create a command-line argument parser. Generates a typed Result struct at comptime.
///
/// ```zig
/// const App = zargparse.Parser("mytool", "Does stuff.", &.{
///     .{ .name = "file", .positional = true, .required = true, .help = "Input file" },
///     .{ .name = "output", .short = 'o', .help = "Output file" },
///     .{ .name = "verbose", .short = 'v', .flag = true, .type = .boolean },
/// });
///
/// const opts = App.parse(args, io) catch return;
/// // opts.file    : []const u8
/// // opts.output  : ?[]const u8
/// // opts.verbose : bool
/// ```
pub fn Parser(comptime program_name: []const u8, comptime description: []const u8, comptime args: []const Arg) type {
    // Validate arg definitions at comptime
    comptime {
        var positional_count: usize = 0;
        var seen_optional_positional = false;
        for (args) |arg| {
            if (arg.multi)
                @compileError("Argument '" ++ arg.name ++ "': multi-value args require an allocator and are not yet supported");
            if (arg.positional and arg.flag)
                @compileError("Argument '" ++ arg.name ++ "' cannot be both positional and a flag");
            if (arg.positional and arg.multi)
                @compileError("Argument '" ++ arg.name ++ "': positional multi args not supported");
            if (arg.flag and arg.type != .boolean and arg.type != .count)
                @compileError("Argument '" ++ arg.name ++ "': flags must be boolean or count type");
            if (arg.positional) {
                if (seen_optional_positional and arg.required)
                    @compileError("Required positional '" ++ arg.name ++ "' cannot follow optional positional");
                if (!arg.required) seen_optional_positional = true;
                positional_count += 1;
            }
        }
    }

    return struct {
        const Self = @This();
        pub const Result = ResultType(args);
        pub const definitions = args;
        pub const name = program_name;
        pub const desc = description;

        /// Parse with error messages printed to stderr and --help to stdout.
        /// This is what CLI programs should use.
        pub fn parse(raw_args: []const []const u8, io: Io) ParseError!Result {
            return parseCore(raw_args) catch |err| {
                if (err == error.HelpRequested) {
                    printHelp(io);
                    return err;
                }
                // Print error message
                var buf: [4096]u8 = undefined;
                var fw: Io.File.Writer = .init(.stderr(), io, &buf);
                const w = &fw.interface;
                w.print("\x1b[31merror:\x1b[0m {s}\n", .{@errorName(err)}) catch {};
                w.print("Try '{s} --help' for more information.\n", .{name}) catch {};
                w.flush() catch {};
                return err;
            };
        }

        /// Parse without any I/O. Returns errors directly.
        /// Use this in tests or when you want to handle errors yourself.
        pub fn parseRaw(raw_args: []const []const u8) ParseError!Result {
            return parseCore(raw_args);
        }

        fn parseCore(raw_args: []const []const u8) ParseError!Result {
            // Skip argv[0]
            const argv = if (raw_args.len > 0) raw_args[1..] else raw_args;

            var result: Result = undefined;

            // Initialize defaults
            inline for (args) |arg| {
                @field(result, arg.name) = comptime defaultValue(arg);
            }

            // Track which args were set
            var set_flags = [_]bool{false} ** args.len;

            // Collect positional values
            var positional_idx: usize = 0;

            var i: usize = 0;
            while (i < argv.len) : (i += 1) {
                const token = argv[i];

                // --help / -h
                if (std.mem.eql(u8, token, "--help") or std.mem.eql(u8, token, "-h")) {
                    return error.HelpRequested;
                }

                // -- stops option parsing
                if (std.mem.eql(u8, token, "--")) {
                    i += 1;
                    // Rest are positionals
                    while (i < argv.len) : (i += 1) {
                        if (!trySetPositional(&result, &set_flags, &positional_idx, argv[i]))
                            return error.UnexpectedPositional;
                    }
                    break;
                }

                if (std.mem.startsWith(u8, token, "--")) {
                    // Long option
                    const name_part = token[2..];

                    // Handle --key=value
                    if (std.mem.indexOfScalar(u8, name_part, '=')) |eq| {
                        const key = name_part[0..eq];
                        const value = name_part[eq + 1 ..];
                        const idx = findArgByName(key) orelse return error.UnknownOption;
                        try setArgValue(&result, &set_flags, idx, value);
                    } else {
                        const idx = findArgByName(name_part) orelse return error.UnknownOption;
                        if (isFlag(idx)) {
                            setFlag(&result, &set_flags, idx);
                        } else {
                            i += 1;
                            if (i >= argv.len) return error.MissingValue;
                            try setArgValue(&result, &set_flags, idx, argv[i]);
                        }
                    }
                } else if (token.len >= 2 and token[0] == '-' and !isDigit(token[1])) {
                    // Short option(s): -v, -vvv, -o value
                    var j: usize = 1;
                    while (j < token.len) : (j += 1) {
                        const ch = token[j];
                        const idx = findArgByShort(ch) orelse return error.UnknownOption;

                        if (isFlagOrCount(idx)) {
                            setFlag(&result, &set_flags, idx);
                        } else {
                            // Consume rest of token as value, or next arg
                            if (j + 1 < token.len) {
                                try setArgValue(&result, &set_flags, idx, token[j + 1 ..]);
                                break; // consumed rest of token
                            } else {
                                i += 1;
                                if (i >= argv.len) return error.MissingValue;
                                try setArgValue(&result, &set_flags, idx, argv[i]);
                            }
                        }
                    }
                } else {
                    // Positional
                    if (!trySetPositional(&result, &set_flags, &positional_idx, token))
                        return error.UnexpectedPositional;
                }
            }

            // Check required args
            inline for (args, 0..) |arg, idx| {
                if (arg.required and !set_flags[idx]) {
                    return error.MissingRequired;
                }
            }

            return result;
        }

        fn findArgByName(key: []const u8) ?usize {
            inline for (args, 0..) |arg, idx| {
                if (std.mem.eql(u8, arg.name, key)) return idx;
            }
            return null;
        }

        fn findArgByShort(ch: u8) ?usize {
            inline for (args, 0..) |arg, idx| {
                if (arg.short) |s| {
                    if (s == ch) return idx;
                }
            }
            return null;
        }

        fn isFlag(idx: usize) bool {
            inline for (args, 0..) |arg, i| {
                if (i == idx) return arg.flag;
            }
            return false;
        }

        fn isFlagOrCount(idx: usize) bool {
            inline for (args, 0..) |arg, i| {
                if (i == idx) return arg.flag or arg.type == .count;
            }
            return false;
        }

        fn trySetPositional(result: *Result, set_flags: *[args.len]bool, positional_idx: *usize, value: []const u8) bool {
            comptime var pos_order: [args.len]usize = undefined;
            comptime var pos_count: usize = 0;
            inline for (args, 0..) |arg, idx| {
                if (arg.positional) {
                    pos_order[pos_count] = idx;
                    pos_count += 1;
                }
            }

            if (positional_idx.* >= pos_count) return false;

            const idx = pos_order[positional_idx.*];
            setArgValue(result, set_flags, idx, value) catch return false;
            positional_idx.* += 1;
            return true;
        }

        fn setFlag(result: *Result, set_flags: *[args.len]bool, idx: usize) void {
            inline for (args, 0..) |arg, i| {
                if (i == idx) {
                    if (comptime arg.type == .count) {
                        @field(result, arg.name) += 1;
                    } else if (comptime arg.flag) {
                        @field(result, arg.name) = true;
                    }
                    set_flags[i] = true;
                }
            }
        }

        fn setArgValue(result: *Result, set_flags: *[args.len]bool, idx: usize, value: []const u8) ParseError!void {
            inline for (args, 0..) |arg, i| {
                if (i == idx) {
                    // Validate choices
                    if (arg.choices) |choices| {
                        var valid = false;
                        for (choices) |c| {
                            if (std.mem.eql(u8, value, c)) {
                                valid = true;
                                break;
                            }
                        }
                        if (!valid) return error.InvalidChoice;
                    }

                    // Parse and set
                    @field(result, arg.name) = try parseValueForArg(arg, value);
                    set_flags[i] = true;
                }
            }
        }

        fn parseValueForArg(comptime arg: Arg, value: []const u8) ParseError!argZigType(arg) {
            const unwrapped = switch (arg.type) {
                .string => value,
                .int => std.fmt.parseInt(i64, value, 10) catch return error.InvalidValue,
                .float => std.fmt.parseFloat(f64, value) catch return error.InvalidValue,
                .boolean => parseBoolean(value) orelse return error.InvalidValue,
                .count => std.fmt.parseInt(usize, value, 10) catch return error.InvalidValue,
            };

            // Wrap in optional if needed
            if (comptime !arg.required and !arg.positional and !arg.multi and !arg.flag and arg.type != .count) {
                return @as(?argBaseType(arg), unwrapped);
            }
            return unwrapped;
        }

        fn parseBoolean(value: []const u8) ?bool {
            if (std.mem.eql(u8, value, "true") or
                std.mem.eql(u8, value, "1") or
                std.mem.eql(u8, value, "yes")) return true;
            if (std.mem.eql(u8, value, "false") or
                std.mem.eql(u8, value, "0") or
                std.mem.eql(u8, value, "no")) return false;
            return null;
        }

        fn defaultValue(comptime arg: Arg) argZigType(arg) {
            if (arg.type == .count) return 0;
            if (arg.flag) return false;
            if (arg.multi) return &.{};

            if (arg.default) |d| {
                // Parse default at comptime
                return comptime switch (arg.type) {
                    .string => blk: {
                        if (!arg.required and !arg.positional) break :blk @as(?[]const u8, d);
                        break :blk d;
                    },
                    .int => blk: {
                        const v = std.fmt.parseInt(i64, d, 10) catch @compileError("Invalid default int for '" ++ arg.name ++ "'");
                        if (!arg.required and !arg.positional) break :blk @as(?i64, v);
                        break :blk v;
                    },
                    .float => blk: {
                        const v = std.fmt.parseFloat(f64, d) catch @compileError("Invalid default float for '" ++ arg.name ++ "'");
                        if (!arg.required and !arg.positional) break :blk @as(?f64, v);
                        break :blk v;
                    },
                    .boolean => blk: {
                        const v = std.mem.eql(u8, d, "true");
                        if (!arg.required and !arg.positional) break :blk @as(?bool, v);
                        break :blk v;
                    },
                    .count => 0,
                };
            }

            // No default
            if (!arg.required and !arg.positional and !arg.flag and arg.type != .count) {
                return null; // optional => null
            }

            // Required with no default — will be set during parsing or error
            return undefined;
        }

        // =============================================================================
        // Help Generation
        // =============================================================================

        pub fn printHelp(io: Io) void {
            var buf: [8192]u8 = undefined;
            var fw: Io.File.Writer = .init(.stdout(), io, &buf);
            const w = &fw.interface;

            // Usage line
            w.print("\x1b[1mUsage:\x1b[0m {s}", .{name}) catch {};
            // Options summary
            inline for (args) |arg| {
                if (!arg.positional) {
                    if (arg.required) {
                        w.print(" --{s}", .{arg.name}) catch {};
                        if (!arg.flag) {
                            w.print(" <{s}>", .{arg.metavar orelse upperName(arg.name)}) catch {};
                        }
                    }
                }
            }
            // Optional options
            inline for (args) |arg| {
                if (!arg.positional and !arg.required) {
                    w.print(" [--{s}", .{arg.name}) catch {};
                    if (!arg.flag and arg.type != .count) {
                        w.print(" <{s}>", .{arg.metavar orelse upperName(arg.name)}) catch {};
                    }
                    w.print("]", .{}) catch {};
                }
            }
            // Positionals
            inline for (args) |arg| {
                if (arg.positional) {
                    if (arg.required) {
                        w.print(" <{s}>", .{arg.name}) catch {};
                    } else {
                        w.print(" [{s}]", .{arg.name}) catch {};
                    }
                }
            }
            w.print("\n", .{}) catch {};

            // Description
            if (desc.len > 0) {
                w.print("\n{s}\n", .{desc}) catch {};
            }

            // Positional arguments section
            comptime var has_positional = false;
            inline for (args) |arg| {
                if (arg.positional) has_positional = true;
            }
            if (has_positional) {
                w.print("\n\x1b[1mPositional arguments:\x1b[0m\n", .{}) catch {};
                inline for (args) |arg| {
                    if (arg.positional) {
                        w.print("  {s:<24} {s}", .{ arg.name, arg.help }) catch {};
                        if (arg.default) |d| {
                            w.print(" (default: {s})", .{d}) catch {};
                        }
                        if (arg.choices) |choices| {
                            w.print(" {{", .{}) catch {};
                            for (choices, 0..) |c, ci| {
                                if (ci > 0) w.print(", ", .{}) catch {};
                                w.print("{s}", .{c}) catch {};
                            }
                            w.print("}}", .{}) catch {};
                        }
                        w.print("\n", .{}) catch {};
                    }
                }
            }

            // Options section
            w.print("\n\x1b[1mOptions:\x1b[0m\n", .{}) catch {};
            w.print("  -h, --help               Show this help message\n", .{}) catch {};
            inline for (args) |arg| {
                if (!arg.positional) {
                    // Short flag
                    if (arg.short) |s| {
                        w.print("  -{c}, ", .{s}) catch {};
                    } else {
                        w.print("      ", .{}) catch {};
                    }

                    // Long flag + metavar
                    w.print("--{s}", .{arg.name}) catch {};
                    if (!arg.flag and arg.type != .count) {
                        w.print(" <{s}>", .{arg.metavar orelse upperName(arg.name)}) catch {};
                    }

                    // Pad to help column
                    const col = blk: {
                        var c: usize = 6 + 2 + arg.name.len;
                        if (!arg.flag and arg.type != .count) {
                            c += 3 + (arg.metavar orelse upperName(arg.name)).len;
                        }
                        break :blk c;
                    };
                    if (col < 24) {
                        for (0..24 - col) |_| w.writeByte(' ') catch {};
                    } else {
                        w.writeByte(' ') catch {};
                    }

                    w.print("{s}", .{arg.help}) catch {};

                    if (arg.required) {
                        w.print(" \x1b[31m(required)\x1b[0m", .{}) catch {};
                    }
                    if (arg.default) |d| {
                        w.print(" \x1b[90m(default: {s})\x1b[0m", .{d}) catch {};
                    }
                    if (arg.choices) |choices| {
                        w.print(" \x1b[90m{{", .{}) catch {};
                        for (choices, 0..) |c, ci| {
                            if (ci > 0) w.print(", ", .{}) catch {};
                            w.print("{s}", .{c}) catch {};
                        }
                        w.print("}}\x1b[0m", .{}) catch {};
                    }
                    w.print("\n", .{}) catch {};
                }
            }

            w.flush() catch {};
        }

        fn upperName(comptime input: []const u8) *const [input.len]u8 {
            return &comptime blk: {
                var buf: [input.len]u8 = undefined;
                for (input, 0..) |c, idx| {
                    buf[idx] = if (c >= 'a' and c <= 'z') c - 32 else if (c == '-') '_' else c;
                }
                break :blk buf;
            };
        }

        fn isDigit(c: u8) bool {
            return c >= '0' and c <= '9';
        }
    };
}

/// Errors returned by parse() and parseRaw().
pub const ParseError = error{
    /// User passed --help or -h
    HelpRequested,
    /// Unrecognized --flag or -x
    UnknownOption,
    /// Option expects a value but none was provided
    MissingValue,
    /// A required argument was not provided
    MissingRequired,
    /// Value couldn't be parsed as the expected type
    InvalidValue,
    /// Value not in the choices list
    InvalidChoice,
    /// Too many positional arguments
    UnexpectedPositional,
};

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

const Simple = Parser("test", "A test program.", &.{
    .{ .name = "input", .positional = true, .required = true, .help = "Input file" },
    .{ .name = "output", .short = 'o', .help = "Output file" },
    .{ .name = "verbose", .short = 'v', .flag = true, .type = .boolean, .help = "Verbose" },
    .{ .name = "count", .short = 'n', .type = .int, .default = "1", .help = "Count" },
});

test "positional required" {
    const argv = [_][]const u8{ "test", "hello.txt" };
    const result = try Simple.parseRaw(&argv);
    try testing.expectEqualStrings("hello.txt", result.input);
}

test "missing required returns error" {
    const argv = [_][]const u8{"test"};
    const result = Simple.parseRaw(&argv);
    try testing.expectError(error.MissingRequired, result);
}

test "long option" {
    const argv = [_][]const u8{ "test", "--output", "out.txt", "in.txt" };
    const result = try Simple.parseRaw(&argv);
    try testing.expectEqualStrings("in.txt", result.input);
    try testing.expectEqualStrings("out.txt", result.output.?);
}

test "long option with equals" {
    const argv = [_][]const u8{ "test", "--output=out.txt", "in.txt" };
    const result = try Simple.parseRaw(&argv);
    try testing.expectEqualStrings("out.txt", result.output.?);
}

test "short option" {
    const argv = [_][]const u8{ "test", "-o", "out.txt", "in.txt" };
    const result = try Simple.parseRaw(&argv);
    try testing.expectEqualStrings("out.txt", result.output.?);
}

test "short option attached value" {
    const argv = [_][]const u8{ "test", "-oout.txt", "in.txt" };
    const result = try Simple.parseRaw(&argv);
    try testing.expectEqualStrings("out.txt", result.output.?);
}

test "boolean flag" {
    const argv = [_][]const u8{ "test", "-v", "in.txt" };
    const result = try Simple.parseRaw(&argv);
    try testing.expect(result.verbose);
}

test "boolean flag default false" {
    const argv = [_][]const u8{ "test", "in.txt" };
    const result = try Simple.parseRaw(&argv);
    try testing.expect(!result.verbose);
}

test "int option" {
    const argv = [_][]const u8{ "test", "-n", "42", "in.txt" };
    const result = try Simple.parseRaw(&argv);
    try testing.expectEqual(@as(?i64, 42), result.count);
}

test "int option default" {
    const argv = [_][]const u8{ "test", "in.txt" };
    const result = try Simple.parseRaw(&argv);
    try testing.expectEqual(@as(?i64, 1), result.count);
}

test "stacked short flags" {
    const argv = [_][]const u8{ "test", "-vn", "3", "in.txt" };
    const result = try Simple.parseRaw(&argv);
    try testing.expect(result.verbose);
    try testing.expectEqual(@as(?i64, 3), result.count);
}

test "unknown option returns error" {
    const argv = [_][]const u8{ "test", "--bogus", "in.txt" };
    const result = Simple.parseRaw(&argv);
    try testing.expectError(error.UnknownOption, result);
}

test "invalid int value returns error" {
    const argv = [_][]const u8{ "test", "-n", "abc", "in.txt" };
    const result = Simple.parseRaw(&argv);
    try testing.expectError(error.InvalidValue, result);
}

test "optional field is null when not provided" {
    const argv = [_][]const u8{ "test", "in.txt" };
    const result = try Simple.parseRaw(&argv);
    try testing.expect(result.output == null);
}

test "double dash stops option parsing" {
    const argv = [_][]const u8{ "test", "--", "--not-a-flag" };
    const result = try Simple.parseRaw(&argv);
    try testing.expectEqualStrings("--not-a-flag", result.input);
}

// Count flag tests
const CountApp = Parser("counter", "Count flags.", &.{
    .{ .name = "verbose", .short = 'v', .flag = true, .type = .count, .help = "Verbosity" },
    .{ .name = "file", .positional = true, .required = true, .help = "File" },
});

test "count flag single" {
    const argv = [_][]const u8{ "counter", "-v", "f.txt" };
    const result = try CountApp.parseRaw(&argv);
    try testing.expectEqual(@as(usize, 1), result.verbose);
}

test "count flag stacked" {
    const argv = [_][]const u8{ "counter", "-vvv", "f.txt" };
    const result = try CountApp.parseRaw(&argv);
    try testing.expectEqual(@as(usize, 3), result.verbose);
}

test "count flag repeated long" {
    const argv = [_][]const u8{ "counter", "--verbose", "--verbose", "f.txt" };
    const result = try CountApp.parseRaw(&argv);
    try testing.expectEqual(@as(usize, 2), result.verbose);
}

test "count flag default zero" {
    const argv = [_][]const u8{ "counter", "f.txt" };
    const result = try CountApp.parseRaw(&argv);
    try testing.expectEqual(@as(usize, 0), result.verbose);
}

// Choice validation tests
const ChoiceApp = Parser("chooser", "Pick a format.", &.{
    .{ .name = "format", .short = 'f', .choices = &.{ "json", "csv", "xml" }, .default = "json", .help = "Format" },
});

test "valid choice" {
    const argv = [_][]const u8{ "chooser", "-f", "csv" };
    const result = try ChoiceApp.parseRaw(&argv);
    try testing.expectEqualStrings("csv", result.format.?);
}

test "invalid choice returns error" {
    const argv = [_][]const u8{ "chooser", "-f", "yaml" };
    const result = ChoiceApp.parseRaw(&argv);
    try testing.expectError(error.InvalidChoice, result);
}

test "choice default" {
    const argv = [_][]const u8{"chooser"};
    const result = try ChoiceApp.parseRaw(&argv);
    try testing.expectEqualStrings("json", result.format.?);
}

// Help request test
test "help returns HelpRequested" {
    const argv = [_][]const u8{ "test", "--help" };
    const result = Simple.parseRaw(&argv);
    try testing.expectError(error.HelpRequested, result);
}

test "short help returns HelpRequested" {
    const argv = [_][]const u8{ "test", "-h" };
    const result = Simple.parseRaw(&argv);
    try testing.expectError(error.HelpRequested, result);
}

// Type generation tests
test "Result type has correct field types" {
    try testing.expect(@TypeOf(@as(Simple.Result, undefined).input) == []const u8);
    try testing.expect(@TypeOf(@as(Simple.Result, undefined).output) == ?[]const u8);
    try testing.expect(@TypeOf(@as(Simple.Result, undefined).verbose) == bool);
    try testing.expect(@TypeOf(@as(Simple.Result, undefined).count) == ?i64);
}

test "count Result type is usize" {
    try testing.expect(@TypeOf(@as(CountApp.Result, undefined).verbose) == usize);
}

// Mixed stacked short flags: flag + value-consuming option combined
test "mixed short flag and value attached" {
    const Mixed = Parser("mixed", "", &.{
        .{ .name = "verbose", .short = 'v', .flag = true, .type = .boolean },
        .{ .name = "output", .short = 'o' },
    });

    const argv = [_][]const u8{ "mixed", "-voout.txt" };
    const result = try Mixed.parseRaw(&argv);
    try testing.expect(result.verbose);
    try testing.expectEqualStrings("out.txt", result.output.?);
}

// Missing value for option that expects one
test "missing value for option" {
    const argv = [_][]const u8{ "test", "--output" };
    const result = Simple.parseRaw(&argv);
    try testing.expectError(error.MissingValue, result);
}

test "missing value for short option" {
    const argv = [_][]const u8{ "test", "-o" };
    const result = Simple.parseRaw(&argv);
    try testing.expectError(error.MissingValue, result);
}
