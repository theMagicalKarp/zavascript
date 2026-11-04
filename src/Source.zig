//! A source file's path and text, plus the offsets of each line start so a byte offset can be
//! turned into the 1-based line and column tsc reports.

const std = @import("std");

const Source = @This();

path: []const u8,
text: []const u8,
/// Byte offset of the first character of each line; `line_starts[0]` is always 0.
line_starts: []const u32,

/// `path` and `text` must outlive the returned `Source`; only the line table is allocated.
pub fn init(gpa: std.mem.Allocator, path: []const u8, text: []const u8) !Source {
    var starts: std.ArrayList(u32) = .empty;
    errdefer starts.deinit(gpa);
    try starts.append(gpa, 0);
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        switch (text[i]) {
            '\n' => try starts.append(gpa, @intCast(i + 1)),
            '\r' => {
                if (i + 1 < text.len and text[i + 1] == '\n') i += 1;
                try starts.append(gpa, @intCast(i + 1));
            },
            // U+2028 LINE SEPARATOR and U+2029 PARAGRAPH SEPARATOR.
            0xE2 => if (i + 2 < text.len and text[i + 1] == 0x80 and (text[i + 2] == 0xA8 or text[i + 2] == 0xA9)) {
                i += 2;
                try starts.append(gpa, @intCast(i + 1));
            },
            else => {},
        }
    }
    return .{ .path = path, .text = text, .line_starts = try starts.toOwnedSlice(gpa) };
}

pub fn deinit(this: *Source, gpa: std.mem.Allocator) void {
    gpa.free(this.line_starts);
    this.* = undefined;
}

pub const Location = struct {
    /// 1-based.
    line: u32,
    /// 1-based, counted in UTF-16 code units like tsc does.
    column: u32,
};

pub fn location(this: Source, offset: u32) Location {
    // The last line start that is <= offset.
    var lo: usize = 0;
    var hi: usize = this.line_starts.len;
    while (hi - lo > 1) {
        const mid = lo + (hi - lo) / 2;
        if (this.line_starts[mid] <= offset) lo = mid else hi = mid;
    }
    const start = this.line_starts[lo];
    const end = @min(offset, this.text.len);
    return .{ .line = @intCast(lo + 1), .column = @intCast(utf16Length(this.text[start..end]) + 1) };
}

/// The number of UTF-16 code units `bytes` would take; invalid bytes count as one each.
fn utf16Length(bytes: []const u8) usize {
    var n: usize = 0;
    for (bytes) |byte| {
        if (byte & 0xC0 == 0x80) continue; // continuation byte
        n += if (byte >= 0xF0) 2 else 1; // four-byte sequences are surrogate pairs
    }
    return n;
}

test location {
    var source: Source = try .init(std.testing.allocator, "a.ts", "ab\ncd\r\nef\r€x\u{1F600}y");
    defer source.deinit(std.testing.allocator);
    try std.testing.expectEqual(Location{ .line = 1, .column = 1 }, source.location(0));
    try std.testing.expectEqual(Location{ .line = 1, .column = 3 }, source.location(2));
    try std.testing.expectEqual(Location{ .line = 2, .column = 2 }, source.location(4));
    try std.testing.expectEqual(Location{ .line = 3, .column = 1 }, source.location(7));
    try std.testing.expectEqual(Location{ .line = 4, .column = 1 }, source.location(10));
    // '€' is 3 bytes but one UTF-16 unit; the emoji is 4 bytes and two units.
    try std.testing.expectEqual(Location{ .line = 4, .column = 2 }, source.location(13));
    try std.testing.expectEqual(Location{ .line = 4, .column = 5 }, source.location(18));
}
