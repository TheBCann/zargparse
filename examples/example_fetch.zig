/// Example: HTTP fetcher with rich CLI options
///
/// Usage:
///   zig run example_fetch.zig -- https://example.com
///   zig run example_fetch.zig -- -X POST --timeout 10 --format json https://api.example.com/data
///   zig run example_fetch.zig -- -vvv --output result.txt https://example.com
///   zig run example_fetch.zig -- --help
const std = @import("std");
const Io = std.Io;
const process = std.process;
const argparse = @import("argparse.zig");

const Fetch = argparse.Parser("zfetch", "A simple HTTP client.", &.{
    .{
        .name = "url",
        .positional = true,
        .required = true,
        .help = "URL to fetch",
    },
    .{
        .name = "method",
        .short = 'X',
        .help = "HTTP method",
        .default = "GET",
        .choices = &.{ "GET", "POST", "PUT", "DELETE", "HEAD", "PATCH" },
    },
    .{
        .name = "output",
        .short = 'o',
        .help = "Write response body to file",
        .metavar = "FILE",
    },
    .{
        .name = "timeout",
        .short = 't',
        .type = .int,
        .help = "Request timeout in seconds",
        .default = "30",
        .metavar = "SECS",
    },
    .{
        .name = "format",
        .short = 'f',
        .help = "Output format",
        .default = "raw",
        .choices = &.{ "raw", "json", "headers" },
    },
    .{
        .name = "verbose",
        .short = 'v',
        .flag = true,
        .type = .count,
        .help = "Increase verbosity (-v, -vv, -vvv)",
    },
    .{
        .name = "follow",
        .short = 'L',
        .flag = true,
        .type = .boolean,
        .help = "Follow redirects",
    },
    .{
        .name = "insecure",
        .short = 'k',
        .flag = true,
        .type = .boolean,
        .help = "Skip TLS verification",
    },
    .{
        .name = "user_agent",
        .short = 'A',
        .help = "User-Agent string",
        .default = "zfetch/1.0",
        .metavar = "UA",
    },
});

pub fn main(init: process.Init) !void {
    const io = init.io;

    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const opts = Fetch.parse(args, io) catch return;

    var stdout_buf: [8192]u8 = undefined;
    var fw: Io.File.Writer = .init(.stdout(), io, &stdout_buf);
    const w = &fw.interface;

    // Demonstration: just print parsed options
    try w.print("Parsed options:\n", .{});
    try w.print("  url:        {s}\n", .{opts.url});
    try w.print("  method:     {s}\n", .{opts.method.?});
    try w.print("  timeout:    {}s\n", .{opts.timeout.?});
    try w.print("  format:     {s}\n", .{opts.format.?});
    try w.print("  user_agent: {s}\n", .{opts.user_agent.?});
    try w.print("  verbose:    {}\n", .{opts.verbose});
    try w.print("  follow:     {}\n", .{opts.follow});
    try w.print("  insecure:   {}\n", .{opts.insecure});

    if (opts.output) |out| {
        try w.print("  output:     {s}\n", .{out});
    } else {
        try w.print("  output:     (stdout)\n", .{});
    }

    try w.flush();
}
