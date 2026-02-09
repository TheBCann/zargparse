/// Minimal argparse example
///
/// Usage:
///   zig run example_minimal.zig -- world
///   zig run example_minimal.zig -- --shout world
///   zig run example_minimal.zig -- -n 5 world
const std = @import("std");
const Io = std.Io;
const process = std.process;
const argparse = @import("argparse.zig");

const App = argparse.Parser("hello", "Greet someone.", &.{
    .{ .name = "name", .positional = true, .required = true, .help = "Who to greet" },
    .{ .name = "shout", .short = 's', .flag = true, .type = .boolean, .help = "SHOUT the greeting" },
    .{ .name = "repeat", .short = 'n', .type = .int, .default = "1", .help = "Repeat N times" },
});

pub fn main(init: process.Init) !void {
    const io = init.io;

    const raw = try init.minimal.args.toSlice(init.arena.allocator());
    const opts = App.parse(raw, io) catch return;

    var stdout_buf: [4096]u8 = undefined;
    var fw: Io.File.Writer = .init(.stdout(), io, &stdout_buf);
    const w = &fw.interface;

    const n: usize = @intCast(opts.repeat.?);
    for (0..n) |_| {
        if (opts.shout) {
            // Manual uppercase
            for (opts.name) |c| {
                try w.writeByte(if (c >= 'a' and c <= 'z') c - 32 else c);
            }
            try w.print("!!!\n", .{});
        } else {
            try w.print("Hello, {s}!\n", .{opts.name});
        }
    }

    try w.flush();
}
