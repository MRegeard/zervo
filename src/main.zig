const std = @import("std");
const Allocator = std.mem.Allocator;
const Args = std.process.Args;
const Io = std.Io;
const File = Io.File;
const http = std.http;
const Status = http.Status;
const Method = http.Method;
const assert = std.debug.assert;
const ext = @import("ext.zig");
const Ext = ext.Ext;

const port: u16 = 8000;
const add_text: []const u8 = "127.0.0.1";

const usage =
    \\Usage: zervos [Optional] Path {./}
    \\
;

pub fn parseArgs(allocator: Allocator, args: Args) ![]const u8 {
    var args_it = try args.iterateAllocator(allocator);
    _ = args_it.skip();

    if (args_it.next()) |path| {
        if (args_it.next() != null) {
            std.log.info("{s}", .{usage});
            std.process.fatal("Only one command line argument `Path` supported.", .{});
        }
        return path;
    } else {
        return "./";
    }
}

const App = struct {
    root_dir: []const u8,
    log: *Io.Writer,
    loop_allocator: Allocator,
};

pub fn main(init: std.process.Init) !void {
    const allocator: Allocator = init.arena.allocator();
    const io: Io = init.io;

    var loop_arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer loop_arena.deinit();
    const loop_allocator = loop_arena.allocator();

    var log_buf: [1024]u8 = undefined;
    var log_writer = Io.File.stdout().writer(io, &log_buf);
    const log: *Io.Writer = &log_writer.interface;

    const root_dir = try parseArgs(allocator, init.minimal.args);

    const address: Io.net.IpAddress = try .parse(add_text, port);

    var server = try address.listen(io, .{ .reuse_address = true });
    defer server.deinit(io);

    const app: App = .{
        .root_dir = root_dir,
        .log = log,
        .loop_allocator = loop_allocator,
    };

    var stream_write_buf: [1024]u8 = undefined;
    var read_buf: [8192]u8 = undefined;

    while (true) {
        _ = loop_arena.reset(.retain_capacity);

        var stream = try server.accept(io);
        defer stream.close(io);

        var stream_writer = stream.writer(io, &stream_write_buf);
        const writer: *Io.Writer = &stream_writer.interface;

        var stream_reader = stream.reader(io, &read_buf);
        const reader: *Io.Reader = &stream_reader.interface;

        handleConnection(io, app, writer, reader) catch |err| {
            try app.log.print("ERROR: {s}\n", .{@errorName(err)});
        };
    }
}

pub fn handleConnection(io: Io, app: App, writer: *Io.Writer, reader: *Io.Reader) !void {
    const line1 = std.mem.trim(u8, (try reader.takeDelimiter('\n')) orelse return, "\r");
    const first_line = FirstLine.parse(app.loop_allocator, line1) catch {
        try sendResponse(writer, .bad_request);
        return;
    };

    try stdoutHeader(app.log, reader, first_line);

    if (first_line.method != .GET) {
        try sendResponse(writer, .method_not_allowed);
        return;
    }
    if (!isSafePath(first_line.path)) {
        try sendResponse(writer, .bad_request);
        return;
    }

    const request_path = try fileRequest(app.loop_allocator, app.root_dir, first_line.path);

    const mime = Ext.fromPath(request_path).toMIME();

    const file = Io.Dir.cwd().openFile(io, request_path, .{ .allow_directory = false }) catch |err| switch (err) {
        error.FileNotFound, error.IsDir => {
            try sendResponse(writer, .not_found);
            return;
        },
        else => {
            try sendResponse(writer, .internal_server_error);
            return;
        },
    };
    defer file.close(io);

    try sendResponseFile(io, writer, &file, mime);
}

const FirstLine = struct {
    pub const Error = error{ParseError} || Allocator.Error;

    method: Method,
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

pub fn sendResponseFile(io: Io, writer: *Io.Writer, file: *const File, content_type: []const u8) !void {
    var buf: [4096]u8 = undefined;
    var file_reader = file.reader(io, &buf);
    const file_size = (try file.stat(io)).size;

    const to_print =
        "HTTP/1.1 200 OK\r\n" ++
        "Content-type: {s}\r\n" ++
        "Content-length: {d}\r\n" ++
        "Connection: close\r\n" ++
        "\r\n";
    try writer.print(to_print, .{ content_type, file_size });
    const bytes_send = try writer.sendFileReadingAll(&file_reader, .limited64(file_size));
    assert(bytes_send == file_size);
    try writer.flush();
}

pub fn sendResponse(writer: *Io.Writer, status: Status) !void {
    const status_text = status.phrase().?;
    const status_int = @intFromEnum(status);
    const to_print =
        "HTTP/1.1 {d} {s}\r\n" ++
        "Content-type: text/html\r\n" ++
        "Content-length: {d}\r\n" ++
        "Connection: close\r\n" ++
        "\r\n" ++
        "<h1>{d} {s}</h1>";
    try writer.print(to_print, .{ status_int, status_text, status_text.len + 13, status_int, status_text });
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

pub fn isSafePath(path: []const u8) bool {
    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |segment| {
        if (std.mem.eql(u8, segment, "..")) {
            return false;
        }
    }
    return true;
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
