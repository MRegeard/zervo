const std = @import("std");
const Io = std.Io;

const port: u16 = 8000;
const add_text: []const u8 = "127.0.0.1";
const body: []const u8 = "<h1>Hello</h1>";

pub fn main() !void {
    var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena.deinit();
    //const allocator = arena.allocator();

    var threaded: Io.Threaded = .init_single_threaded;
    const io: Io = threaded.io();

    var write_buf: [1024]u8 = undefined;
    var stdout_writer = Io.File.stdout().writer(io, &write_buf);
    const stdout: *Io.Writer = &stdout_writer.interface;

    const address: Io.net.IpAddress = try .parse(add_text, port);

    var server = try address.listen(io, .{.reuse_address = true});
    defer server.deinit(io);

    while (true) {
        var stream = try server.accept(io);
        defer stream.close(io);

        var stream_write_buf: [1024]u8 = undefined;
        var stream_writer = stream.writer(io, &stream_write_buf);
        const writer: *Io.Writer = &stream_writer.interface;

        try stdout.writeAll("--- New Connection ---\n");

        var read_buf: [1024]u8 = undefined;
        var stream_reader = stream.reader(io, &read_buf);
        const reader: *Io.Reader = &stream_reader.interface;

        while (try reader.takeDelimiter('\n')) |line| {
            if (!std.mem.startsWith(u8, line, "\r")) {
                try stdout.print("{s}\n", .{line[0..line.len]});
            } else {
                break;
            }
        }
        try stdout.flush();

        try writer.print("HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: {d}\r\n\r\n{s}", .{body.len, body});
        try writer.flush();
    }
}
