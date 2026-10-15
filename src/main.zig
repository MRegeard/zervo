const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Io = std.Io;

const port: u16 = 8000;
const add_text: []const u8 = "127.0.0.1";

const max_file_size = 10 * 1024 * 1024;

pub const Ext = enum {
    html,
    css,
    js,
    json,
    txt,
    svg,
    png,
    jpg,
    jpeg,
    gif,
    webp,
    ico,
    pdf,
    other,

    pub fn fromString(ext: []const u8) Ext {
        const trim_ext = std.mem.trimStart(u8, ext, ".");
        return std.meta.stringToEnum(Ext, trim_ext) orelse .other;
    }

    pub fn toMIME(self: Ext) []const u8 {
        return switch (self) {
            .html => "text/html; charset=utf-8",
            .css => "text/css; charset=utf-8",
            .js => "text/javascript; charset=utf-8",
            .json => "application/json",
            .txt => "text/plain; charset=utf-8",
            .svg => "image/svg+xml",
            .png => "image/png",
            .jpg, .jpeg => "image/jpeg",
            .gif => "image/gif",
            .webp => "image/webp",
            .ico => "image/x-icon",
            .pdf => "application/pdf",
            .other => "application/octet-stream",
        };
    }
};

const State = struct {
    root_dir: []const u8 = undefined,
};

pub fn main(init: std.process.Init.Minimal) !void {
    var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var state: State = .{};

    var args_it = try init.args.iterateAllocator(allocator);
    _ = args_it.skip();

    if (args_it.next()) |path| {
        state.root_dir = path;
    } else {
        state.root_dir = "./";
    }

    var threaded: Io.Threaded = .init_single_threaded;
    const io: Io = threaded.io();

    var file_read_buffer: [1024]u8 = undefined;

    var write_buf: [1024]u8 = undefined;
    var stdout_writer = Io.File.stdout().writer(io, &write_buf);
    const stdout: *Io.Writer = &stdout_writer.interface;

    const address: Io.net.IpAddress = try .parse(add_text, port);

    var server = try address.listen(io, .{ .reuse_address = true });
    defer server.deinit(io);

    var read_buf: [8192]u8 = undefined;
    var stream_write_buf: [1024]u8 = undefined;

    while (true) {
        _ = arena.reset(.retain_capacity);

        var stream = try server.accept(io);
        defer stream.close(io);

        var stream_writer = stream.writer(io, &stream_write_buf);
        const writer: *Io.Writer = &stream_writer.interface;

        var stream_reader = stream.reader(io, &read_buf);
        const reader: *Io.Reader = &stream_reader.interface;

        const line1 = std.mem.trim(u8, (try reader.takeDelimiter('\n')) orelse continue, "\r");
        const first_line = FirstLine.parse(allocator, line1) catch {
            try sendResponse(writer, "400 Bad Request", "text/html", "<h1>400 Bad Request</h1>");
            continue;
        };

        try stdoutHeader(stdout, reader, first_line);

        if (first_line.method != .GET) {
            try sendResponse(writer, "405 Method Not Allowed", "text/html", "<h1>405 Method Not Allowed</h1>");
            continue;
        }

        const request_path = try fileRequest(allocator, state.root_dir, first_line.path);

        // TODO: refactor this
        if (std.mem.containsAtLeast(u8, request_path, 1, "/../")) {
            try sendResponse(writer, "400 Bad Request", "text/html", "<h1>400 Bad Request</h1>");
        }

        const ext = std.mem.trim(u8, std.fs.path.extension(request_path), ".");
        const ext_lower = try lowercaseAlloc(allocator, ext);
        const mime = Ext.fromString(ext_lower).toMIME();

        const file = Io.Dir.cwd().openFile(io, request_path, .{}) catch |err| switch (err) {
            error.FileNotFound => {
                try sendResponse(writer, "404 Not Found", "text/html", "<h1>404 Not Found</h1>");
                continue;
            },
            else => {
                try sendResponse(writer, "500 Internal Server Error", "text/html", "<h1>500 Internal Server Error</h1>");
                continue;
            },
        };
        defer file.close(io);

        var f_reader = file.reader(io, &file_read_buffer);
        const file_reader = &f_reader.interface;
        const file_content = try file_reader.allocRemaining(allocator, .limited(max_file_size));

        try sendResponse(writer, "200 OK", mime, file_content);
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
        if (it.next() != null) return Error.ParseError;
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

pub fn fileRequest(allocator: Allocator, root_path: []const u8, path: []const u8) ![]const u8 {
    const pos = std.mem.findScalar(u8, path, '?') orelse path.len;
    const strip_path = path[0..pos];
    if (strip_path.len == 0) {
        return try std.fs.path.join(allocator, &.{ root_path, "index.html" });
    }
    if (std.mem.endsWith(u8, strip_path, "/")) {
        return try std.fs.path.join(allocator, &.{ root_path, strip_path, "index.html" });
    }
    return try std.fs.path.join(allocator, &.{ root_path, strip_path });
}

pub fn lowercaseAlloc(allocator: Allocator, str: []const u8) ![]const u8 {
    const lower = try allocator.alloc(u8, str.len);

    for (0..str.len) |i| {
        switch (str[i]) {
            'A'...'Z' => lower[i] = str[i] + 32,
            else => lower[i] = str[i],
        }
    }
    return lower;
}

pub fn stdoutHeader(writer: *Io.Writer, reader: *Io.Reader, first_line: FirstLine) !void {
    try writer.writeAll("--- New Connection ---\n");

    try writer.print("[{s}] [{s}] [{s}]\n", .{ @tagName(first_line.method), first_line.path, @tagName(first_line.version) });

    while (try reader.takeDelimiter('\n')) |line| {
        const line_trim = std.mem.trim(u8, line, "\r");
        if (line_trim.len != 0) {
            try writer.print("{s}\n", .{line_trim});
        } else {
            break;
        }
    }
    try writer.flush();
}
