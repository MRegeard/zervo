const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const Allocator = std.mem.Allocator;
const builtin = @import("builtin");

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
    wasm,
    tar,
    htm,
    mjs,
    map,
    xml,
    webmanifest,
    woff2,
    woff,
    ttf,
    otf,
    avif,
    mp4,
    webm,
    mp3,
    ogg,
    wav,
    csv,
    md,
    zip,

    default,

    pub fn fromPath(path: []const u8) Ext {
        const ext = std.fs.path.extension(path);
        return .fromString(ext);
    }

    pub fn fromString(ext: []const u8) Ext {
        const trim_ext = std.mem.trimStart(u8, ext, ".");
        var buf: [256]u8 = undefined;
        const low_ext: []const u8 = lowcaseBuffer(trim_ext, &buf);
        return std.meta.stringToEnum(Ext, low_ext) orelse .default;
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
            .wasm => "application/wasm",
            .tar => "application/x-tar",
            .htm => "text/html; charset=utf-8",
            .mjs => "text/javascript; charset=utf-8",
            .map => "application/json",
            .xml => "application/xml",
            .webmanifest => "application/manifest+json",
            .woff2 => "font/woff2",
            .woff => "font/woff",
            .ttf => "font/ttf",
            .otf => "font/otf",
            .avif => "image/avif",
            .mp4 => "video/mp4",
            .webm => "video/webm",
            .mp3 => "audio/mpeg",
            .ogg => "audio/ogg",
            .wav => "audio/wav",
            .csv => "text/csv; charset=utf-8",
            .md => "text/markdown; charset=utf-8",
            .zip => "application/zip",

            .default => "application/octet-stream",
        };
    }
};

pub fn lowcaseBuffer(str: []const u8, buf: []u8) []const u8 {
    if (builtin.mode == .Debug or builtin.mode == .ReleaseSafe) {
        assert(str.len <= buf.len);
    }

    for (0..str.len) |i| {
        switch (str[i]) {
            'A'...'Z' => buf[i] = str[i] + 32,
            else => buf[i] = str[i],
        }
    }
    return buf[0..str.len];
}

test lowcaseBuffer {
    var buf: [256]u8 = undefined;
    try testing.expectEqualSlices(u8, "azerty", lowcaseBuffer("AZERTY", &buf));
    try testing.expectEqualSlices(u8, "az1&dft", lowcaseBuffer("aZ1&2dfT", &buf));
}
