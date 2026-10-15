const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Io = std.Io;

const port: u16 = 8000;
const add_text: []const u8 = "127.0.0.1";
const BODY: []const u8 = "<h1>Hello</h1>";

pub fn main() !void {
    var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var threaded: Io.Threaded = .init_single_threaded;
    const io: Io = threaded.io();

    var write_buf: [1024]u8 = undefined;
    var stdout_writer = Io.File.stdout().writer(io, &write_buf);
    const stdout: *Io.Writer = &stdout_writer.interface;

    const address: Io.net.IpAddress = try .parse(add_text, port);

    var server = try address.listen(io, .{ .reuse_address = true });
    defer server.deinit(io);

    var read_buf: [8192]u8 = undefined;
    var stream_write_buf: [1024]u8 = undefined;
    while (true) {
        var stream = try server.accept(io);
        defer stream.close(io);

        var stream_writer = stream.writer(io, &stream_write_buf);
        const writer: *Io.Writer = &stream_writer.interface;

        try stdout.writeAll("--- New Connection ---\n");

        var stream_reader = stream.reader(io, &read_buf);
        const reader: *Io.Reader = &stream_reader.interface;

        const line1 = std.mem.trim(u8, (try reader.takeDelimiter('\n')) orelse continue, "\r");
        const first_line = FirstLine.parse(allocator, line1) catch {
            try sendResponse(writer, "400 Bad Request", "text/html", "<h1>400 Bad Request</h1>");
            continue;
        };

        try stdout.print("[{s}] [{s}] [{s}]\n", .{ @tagName(first_line.method), first_line.path, @tagName(first_line.version) });

        while (try reader.takeDelimiter('\n')) |line| {
            const line_trim = std.mem.trim(u8, line, "\r");
            if (line_trim.len != 0) {
                try stdout.print("{s}\n", .{line_trim});
            } else {
                break;
            }
        }
        try stdout.flush();

        switch (first_line.method) {
            .GET => try sendResponse(writer, "200 OK", "text/html", BODY),
            else => try sendResponse(writer, "405 Method Not Allowed", "text/html", "<h1>405 Method Not Allowed</h1>"),
        }
    }
}

const FirstLine = struct {
    pub const Error = error{ParseError} || Allocator.Error;

    method: std.http.Method,
    path: []const u8,
    version: std.http.Version,

    pub fn parse(allocator: Allocator, line: []const u8) Error!FirstLine {
        var it = std.mem.splitScalar(u8, line, ' ');
        const method = std.meta.stringToEnum(std.http.Method, (it.next() orelse return Error.ParseError)) orelse return Error.ParseError;
        const path = try allocator.dupe(u8, it.next() orelse return Error.ParseError);
        const version = std.meta.stringToEnum(std.http.Version, (it.next() orelse return Error.ParseError)) orelse return Error.ParseError;
        assert(it.next() == null);
        return .{
            .method = method,
            .path = path,
            .version = version,
        };
    }
};

pub fn sendResponse(writer: *Io.Writer, status: []const u8, content_type: []const u8, body: []const u8) !void {
    try writer.print("HTTP/1.1 {s}\r\nContent-Type: {s}\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}", .{ status, content_type, body.len, body });
    try writer.flush();
}
