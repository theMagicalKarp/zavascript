//! Turns source text into tokens, one at a time. Problems are reported to `diagnostics` and the
//! lexer keeps going, so one bad literal doesn't hide the errors after it.
//!
//! Regular expression literals aren't supported, so `/` is always division.

const std = @import("std");
const Source = @import("../Source.zig");
const diagnostic = @import("../diagnostic.zig");
const token = @import("token.zig");
const Token = token.Token;
const Tag = token.Tag;
const Code = diagnostic.Code;

const Lexer = @This();

source: *const Source,
diagnostics: *diagnostic.Diagnostics,
index: u32 = 0,
/// One entry per open `${` in a template literal: how many `{` are open inside that substitution,
/// so we know which `}` resumes the template.
template_braces: std.ArrayList(u32) = .empty,
gpa: std.mem.Allocator,

pub fn init(gpa: std.mem.Allocator, source: *const Source, diagnostics: *diagnostic.Diagnostics) Lexer {
    var lexer: Lexer = .{ .gpa = gpa, .source = source, .diagnostics = diagnostics };
    // A hashbang line is only allowed at the very start.
    if (std.mem.startsWith(u8, source.text, "#!")) {
        while (lexer.index < source.text.len and !lexer.atLineTerminator()) lexer.index += 1;
    }
    return lexer;
}

pub fn deinit(this: *Lexer) void {
    this.template_braces.deinit(this.gpa);
}

pub const Error = error{OutOfMemory};

pub fn next(this: *Lexer) Error!Token {
    const newline_before = try this.skipTrivia();
    const start = this.index;
    const tag = try this.scan();
    return .{ .tag = tag, .start = start, .end = this.index, .newline_before = newline_before };
}

/// Lexes the whole source, ending with an `eof` token. Mostly for tests.
pub fn tokenize(gpa: std.mem.Allocator, source: *const Source, diagnostics: *diagnostic.Diagnostics) Error![]Token {
    var lexer: Lexer = .init(gpa, source, diagnostics);
    defer lexer.deinit();
    var tokens: std.ArrayList(Token) = .empty;
    errdefer tokens.deinit(gpa);
    while (true) {
        const tok = try lexer.next();
        try tokens.append(gpa, tok);
        if (tok.tag == .eof) return tokens.toOwnedSlice(gpa);
    }
}

fn text(this: *const Lexer) []const u8 {
    return this.source.text;
}

fn peek(this: *const Lexer, ahead: u32) u8 {
    const i = this.index + ahead;
    return if (i < this.text().len) this.text()[i] else 0;
}

fn report(this: *Lexer, at: u32, code: Code, comptime fmt: []const u8, args: anytype) Error!void {
    try this.diagnostics.addSyntax(this.source, at, code, fmt, args);
}

/// The length of the line terminator at the current position, or 0.
fn lineTerminatorLength(this: *const Lexer) u32 {
    return switch (this.peek(0)) {
        '\n' => 1,
        '\r' => if (this.peek(1) == '\n') 2 else 1,
        0xE2 => if (this.peek(1) == 0x80 and (this.peek(2) == 0xA8 or this.peek(2) == 0xA9)) 3 else 0,
        else => 0,
    };
}

fn atLineTerminator(this: *const Lexer) bool {
    return this.lineTerminatorLength() != 0;
}

/// The length of the non-terminator whitespace at the current position, or 0.
fn whitespaceLength(this: *const Lexer) u32 {
    return switch (this.peek(0)) {
        ' ', '\t', 0x0B, 0x0C => 1,
        0xC2 => if (this.peek(1) == 0xA0) 2 else 0, // U+00A0 NO-BREAK SPACE
        0xEF => if (this.peek(1) == 0xBB and this.peek(2) == 0xBF) 3 else 0, // U+FEFF BOM
        else => 0,
    };
}

/// Skips whitespace and comments, returning whether a line terminator was crossed.
fn skipTrivia(this: *Lexer) Error!bool {
    var newline = false;
    while (this.index < this.text().len) {
        const ws = this.whitespaceLength();
        if (ws != 0) {
            this.index += ws;
            continue;
        }
        const lt = this.lineTerminatorLength();
        if (lt != 0) {
            this.index += lt;
            newline = true;
            continue;
        }
        if (this.peek(0) == '/' and this.peek(1) == '/') {
            while (this.index < this.text().len and !this.atLineTerminator()) this.index += 1;
            continue;
        }
        if (this.peek(0) == '/' and this.peek(1) == '*') {
            this.index += 2;
            while (true) {
                if (this.index >= this.text().len) {
                    try this.report(@intCast(this.text().len), .ts(1010), "'*/' expected.", .{});
                    break;
                }
                if (this.peek(0) == '*' and this.peek(1) == '/') {
                    this.index += 2;
                    break;
                }
                const comment_lt = this.lineTerminatorLength();
                if (comment_lt != 0) {
                    newline = true;
                    this.index += comment_lt;
                } else this.index += 1;
            }
            continue;
        }
        break;
    }
    return newline;
}

/// The byte length of the identifier character at the current position, or 0 if there isn't one.
/// `\` escapes aren't handled here; `scan` reports them as unsupported.
fn identifierCharLength(this: *const Lexer, first: bool) u32 {
    const c = this.peek(0);
    if (c < 0x80) {
        const ok = std.ascii.isAlphabetic(c) or c == '_' or c == '$' or (!first and std.ascii.isDigit(c));
        return @intFromBool(ok);
    }
    const len = std.unicode.utf8ByteSequenceLength(c) catch return 0;
    if (this.index + len > this.text().len) return 0;
    const code_point = std.unicode.utf8Decode(this.text()[this.index..][0..len]) catch return 0;
    return if (isIdentifierCodePoint(code_point)) len else 0;
}

/// An approximation of Unicode ID_Start/ID_Continue for non-ASCII code points that avoids carrying
/// the full tables: everything is allowed except the blocks of punctuation, symbols, whitespace and
/// emoji that would otherwise be mistaken for identifiers.
fn isIdentifierCodePoint(cp: u21) bool {
    return switch (cp) {
        0x80...0xA9, 0xAB...0xB4, 0xB6...0xB9, 0xBB...0xBF, 0xD7, 0xF7 => false,
        0x2000...0x2BFF, 0x3000...0x3003, 0x3008...0x3020, 0xFE30...0xFE4F, 0xFEFF => false,
        0xFF00...0xFF0F, 0xFF1A...0xFF20, 0xFF3B...0xFF40, 0xFF5B...0xFF65 => false,
        0xD800...0xDFFF, 0xE000...0xF8FF, 0x1F000...0x1FAFF => false,
        else => true,
    };
}

fn isIdentifierStartAt(this: *const Lexer) bool {
    return this.identifierCharLength(true) != 0;
}

fn skipIdentifierRest(this: *Lexer) void {
    while (true) {
        const len = this.identifierCharLength(false);
        if (len == 0) return;
        this.index += len;
    }
}

fn scan(this: *Lexer) Error!Tag {
    if (this.index >= this.text().len) return .eof;
    const c = this.peek(0);

    if (this.isIdentifierStartAt()) {
        const start = this.index;
        this.skipIdentifierRest();
        return token.keywords.get(this.text()[start..this.index]) orelse .identifier;
    }
    if (std.ascii.isDigit(c) or (c == '.' and std.ascii.isDigit(this.peek(1)))) return this.number();

    switch (c) {
        '"', '\'' => return this.string(c),
        '`' => {
            this.index += 1;
            return this.templateRest(.template_full, .template_head);
        },
        '#' => {
            this.index += 1;
            if (this.isIdentifierStartAt()) {
                this.skipIdentifierRest();
                return .private_name;
            }
            this.index -= 1;
        },
        '{' => {
            if (this.template_braces.items.len > 0) this.template_braces.items[this.template_braces.items.len - 1] += 1;
            this.index += 1;
            return .l_brace;
        },
        '}' => {
            this.index += 1;
            if (this.template_braces.items.len > 0) {
                const open = &this.template_braces.items[this.template_braces.items.len - 1];
                if (open.* == 0) {
                    _ = this.template_braces.pop();
                    return this.templateRest(.template_tail, .template_middle);
                }
                open.* -= 1;
            }
            return .r_brace;
        },
        '\\' => {
            try this.report(this.index, diagnostic.zv.unsupported, "Unicode escapes in identifiers are not supported yet.", .{});
            this.index += 1;
            return .invalid;
        },
        else => {},
    }

    if (this.punctuator()) |tag| return tag;

    // Report one invalid character, consuming the whole UTF-8 sequence.
    try this.report(this.index, .ts(1127), "Invalid character.", .{});
    this.index += std.unicode.utf8ByteSequenceLength(c) catch 1;
    this.index = @min(this.index, @as(u32, @intCast(this.text().len)));
    return .invalid;
}

/// The longest punctuator at the current position, advancing past it.
fn punctuator(this: *Lexer) ?Tag {
    const Entry = struct { []const u8, Tag };
    // Longest first, so the first match is the longest one.
    const table = [_]Entry{
        .{ "...", .ellipsis },           .{ "===", .equal_equal_equal },       .{ "!==", .bang_equal_equal },
        .{ "**=", .star_star_equal },    .{ "<<=", .less_less_equal },         .{ "&&=", .ampersand_ampersand_equal },
        .{ "||=", .pipe_pipe_equal },    .{ "??=", .question_question_equal }, .{ "=>", .arrow },
        .{ "==", .equal_equal },         .{ "!=", .bang_equal },               .{ "<=", .less_equal },
        .{ "<<", .less_less },           .{ "**", .star_star },                .{ "++", .plus_plus },
        .{ "--", .minus_minus },         .{ "+=", .plus_equal },               .{ "-=", .minus_equal },
        .{ "*=", .star_equal },          .{ "/=", .slash_equal },              .{ "%=", .percent_equal },
        .{ "&&", .ampersand_ampersand }, .{ "||", .pipe_pipe },                .{ "&=", .ampersand_equal },
        .{ "|=", .pipe_equal },          .{ "^=", .caret_equal },              .{ "??", .question_question },
        .{ "(", .l_paren },              .{ ")", .r_paren },                   .{ "[", .l_bracket },
        .{ "]", .r_bracket },            .{ ";", .semicolon },                 .{ ",", .comma },
        .{ ":", .colon },                .{ "@", .at },                        .{ "<", .less },
        .{ ">", .greater },              .{ "=", .equal },                     .{ "!", .bang },
        .{ "+", .plus },                 .{ "-", .minus },                     .{ "*", .star },
        .{ "/", .slash },                .{ "%", .percent },                   .{ "&", .ampersand },
        .{ "|", .pipe },                 .{ "^", .caret },                     .{ "~", .tilde },
        .{ "?", .question },             .{ ".", .dot },
    };
    const rest = this.text()[this.index..];
    // `?.` followed by a digit is `?` then a number, as in `a?.5:1`.
    if (std.mem.startsWith(u8, rest, "?.") and !(rest.len > 2 and std.ascii.isDigit(rest[2]))) {
        this.index += 2;
        return .question_dot;
    }
    for (table) |entry| {
        if (std.mem.startsWith(u8, rest, entry[0])) {
            this.index += @intCast(entry[0].len);
            return entry[1];
        }
    }
    return null;
}

const Radix = enum(u8) {
    binary = 2,
    octal = 8,
    decimal = 10,
    hex = 16,

    fn isDigit(this: Radix, c: u8) bool {
        return switch (this) {
            .binary => c == '0' or c == '1',
            .octal => c >= '0' and c <= '7',
            .decimal => std.ascii.isDigit(c),
            .hex => std.ascii.isHex(c),
        };
    }
};

/// Scans digits of `radix` with `_` separators, returning how many digits there were.
fn digits(this: *Lexer, radix: Radix) Error!u32 {
    var count: u32 = 0;
    var last_was_separator = false;
    while (true) {
        const c = this.peek(0);
        if (c == '_') {
            if (count == 0 or last_was_separator) {
                if (last_was_separator)
                    try this.report(this.index, .ts(6189), "Multiple consecutive numeric separators are not permitted.", .{})
                else
                    try this.report(this.index, .ts(6188), "Numeric separators are not allowed here.", .{});
            }
            last_was_separator = true;
            this.index += 1;
        } else if (radix.isDigit(c)) {
            last_was_separator = false;
            count += 1;
            this.index += 1;
        } else break;
    }
    if (last_was_separator) try this.report(this.index - 1, .ts(6188), "Numeric separators are not allowed here.", .{});
    return count;
}

fn number(this: *Lexer) Error!Tag {
    const start = this.index;
    var tag: Tag = .number;
    const prefixed: ?Radix = if (this.peek(0) == '0') switch (this.peek(1)) {
        'x', 'X' => .hex,
        'o', 'O' => .octal,
        'b', 'B' => .binary,
        else => null,
    } else null;

    if (prefixed) |radix| {
        this.index += 2;
        if (try this.digits(radix) == 0) switch (radix) {
            .hex => try this.report(this.index, .ts(1125), "Hexadecimal digit expected.", .{}),
            .octal => try this.report(this.index, .ts(1178), "Octal digit expected.", .{}),
            .binary => try this.report(this.index, .ts(1177), "Binary digit expected.", .{}),
            .decimal => unreachable,
        };
        if (this.peek(0) == 'n') {
            this.index += 1;
            tag = .bigint;
        }
    } else if (this.peek(0) == '0' and std.ascii.isDigit(this.peek(1))) {
        // Legacy octal (`017`) or a decimal with a leading zero (`019`); neither is allowed in
        // strict mode.
        while (std.ascii.isDigit(this.peek(0))) this.index += 1;
        const literal = this.text()[start..this.index];
        if (std.mem.indexOfAny(u8, literal, "89") == null) {
            try this.report(start, .ts(1121), "Octal literals are not allowed. Use the syntax '0o{s}'.", .{literal[1..]});
        } else {
            try this.report(start, .ts(1489), "Decimals with leading zeros are not allowed.", .{});
        }
    } else {
        var integer = true;
        _ = try this.digits(.decimal);
        if (this.peek(0) == '.') {
            integer = false;
            this.index += 1;
            if (this.peek(0) == '_') try this.report(this.index, .ts(6188), "Numeric separators are not allowed here.", .{});
            _ = try this.digits(.decimal);
        }
        if (this.peek(0) == 'e' or this.peek(0) == 'E') {
            integer = false;
            this.index += 1;
            if (this.peek(0) == '+' or this.peek(0) == '-') this.index += 1;
            if (try this.digits(.decimal) == 0) try this.report(this.index, .ts(1124), "Digit expected.", .{});
        }
        if (integer and this.peek(0) == 'n') {
            this.index += 1;
            tag = .bigint;
        }
    }

    // The identifier is left for the next token, as tsc does.
    if (this.identifierCharLength(false) != 0) {
        try this.report(this.index, .ts(1351), "An identifier or keyword cannot immediately follow a numeric literal.", .{});
    }
    return tag;
}

fn string(this: *Lexer, quote: u8) Error!Tag {
    const start = this.index;
    this.index += 1;
    while (true) {
        if (this.index >= this.text().len or this.atLineTerminator()) {
            try this.report(start, .ts(1002), "Unterminated string literal.", .{});
            return .string;
        }
        const c = this.peek(0);
        if (c == quote) {
            this.index += 1;
            return .string;
        }
        if (c == '\\') try this.escape() else this.index += 1;
    }
}

/// Scans the rest of a template after `` ` `` or a substitution's closing `}`. Returns `end_tag`
/// when it ends at a backtick and `substitution_tag` when it ends at `${`.
fn templateRest(this: *Lexer, end_tag: Tag, substitution_tag: Tag) Error!Tag {
    while (true) {
        if (this.index >= this.text().len) {
            // tsc reports this at the end of the file, where the closing backtick is missing.
            try this.report(this.index, .ts(1160), "Unterminated template literal.", .{});
            return end_tag;
        }
        const c = this.peek(0);
        if (c == '`') {
            this.index += 1;
            return end_tag;
        }
        if (c == '$' and this.peek(1) == '{') {
            this.index += 2;
            try this.template_braces.append(this.gpa, 0);
            return substitution_tag;
        }
        if (c == '\\') try this.escape() else this.index += 1;
    }
}

/// Validates one escape sequence starting at the backslash and advances past it. The value is
/// worked out later by `cook`.
fn escape(this: *Lexer) Error!void {
    const start = this.index;
    this.index += 1;
    const c = this.peek(0);
    if (this.index >= this.text().len) return;
    const lt = this.lineTerminatorLength();
    if (lt != 0) {
        this.index += lt; // line continuation
        return;
    }
    switch (c) {
        'x' => {
            this.index += 1;
            if (!(std.ascii.isHex(this.peek(0)) and std.ascii.isHex(this.peek(1)))) {
                try this.report(this.index, .ts(1125), "Hexadecimal digit expected.", .{});
                return;
            }
            this.index += 2;
        },
        'u' => {
            this.index += 1;
            if (this.peek(0) == '{') {
                this.index += 1;
                const digits_start = this.index;
                var value: u32 = 0;
                while (std.ascii.isHex(this.peek(0))) : (this.index += 1) {
                    value = @min(value *| 16 +| (std.fmt.charToDigit(this.peek(0), 16) catch unreachable), 0x110000);
                }
                if (this.index == digits_start) {
                    try this.report(this.index, .ts(1125), "Hexadecimal digit expected.", .{});
                    return;
                }
                if (value > 0x10FFFF) {
                    try this.report(digits_start, .ts(1198), "An extended Unicode escape value must be between 0x0 and 0x10FFFF inclusive.", .{});
                }
                if (this.peek(0) != '}') {
                    try this.report(this.index, .ts(1199), "Unterminated Unicode escape sequence.", .{});
                    return;
                }
                this.index += 1;
            } else {
                var n: u32 = 0;
                while (n < 4 and std.ascii.isHex(this.peek(0))) : (n += 1) this.index += 1;
                if (n < 4) try this.report(this.index, .ts(1125), "Hexadecimal digit expected.", .{});
            }
        },
        '0' => {
            this.index += 1;
            if (std.ascii.isDigit(this.peek(0))) try this.octalEscape(start);
        },
        '1'...'9' => {
            this.index += 1;
            try this.octalEscape(start);
        },
        else => this.index += std.unicode.utf8ByteSequenceLength(c) catch 1,
    }
}

fn octalEscape(this: *Lexer, start: u32) Error!void {
    while (std.ascii.isDigit(this.peek(0))) this.index += 1;
    const escape_text = this.text()[start + 1 .. this.index];
    if (std.mem.indexOfAny(u8, escape_text, "89") != null) {
        try this.report(start, .ts(1488), "Escape sequence '\\{s}' is not allowed.", .{escape_text});
    } else {
        const value = std.fmt.parseInt(u8, escape_text[0..@min(escape_text.len, 3)], 8) catch 0;
        try this.report(start, .ts(1487), "Octal escape sequences are not allowed. Use the syntax '\\x{x:0>2}'.", .{value});
    }
}

/// The value of a string or template token: the text between the delimiters with escapes
/// replaced. The result is WTF-8, since JS strings can hold lone surrogates. Assumes the token
/// already passed `escape`, so malformed escapes are skipped rather than reported.
pub fn cook(allocator: std.mem.Allocator, source: []const u8, tok: Token) Error![]const u8 {
    const raw = tok.text(source);
    const body = switch (tok.tag) {
        .string => raw[1..if (raw.len >= 2 and raw[raw.len - 1] == raw[0]) raw.len - 1 else raw.len],
        .template_full, .template_tail => raw[1..if (std.mem.endsWith(u8, raw, "`")) raw.len - 1 else raw.len],
        .template_head, .template_middle => raw[1 .. raw.len - 2],
        else => unreachable,
    };
    if (std.mem.indexOfAny(u8, body, "\\\r") == null) return body;

    var out: std.ArrayList(u8) = .empty;
    var pending_high: ?u16 = null;
    var i: usize = 0;
    while (i < body.len) {
        const c = body[i];
        if (c == '\r') {
            // Templates normalize CR and CRLF to LF; strings can't contain a raw CR.
            try flushSurrogate(allocator, &out, &pending_high);
            try out.append(allocator, '\n');
            i += if (i + 1 < body.len and body[i + 1] == '\n') 2 else 1;
            continue;
        }
        if (c != '\\' or i + 1 >= body.len) {
            try flushSurrogate(allocator, &out, &pending_high);
            try out.append(allocator, c);
            i += 1;
            continue;
        }
        i += 1;
        const e = body[i];
        i += 1;
        const unit: u21 = switch (e) {
            'n' => '\n',
            't' => '\t',
            'r' => '\r',
            'b' => 0x08,
            'f' => 0x0C,
            'v' => 0x0B,
            '0' => 0,
            '\r' => {
                if (i < body.len and body[i] == '\n') i += 1;
                continue;
            },
            '\n' => continue,
            'x' => blk: {
                if (i + 2 > body.len) continue;
                const v = std.fmt.parseInt(u8, body[i .. i + 2], 16) catch continue;
                i += 2;
                break :blk v;
            },
            'u' => blk: {
                if (i < body.len and body[i] == '{') {
                    const close = std.mem.indexOfScalarPos(u8, body, i, '}') orelse continue;
                    const v = std.fmt.parseInt(u21, body[i + 1 .. close], 16) catch continue;
                    i = close + 1;
                    break :blk v;
                }
                if (i + 4 > body.len) continue;
                const v = std.fmt.parseInt(u16, body[i .. i + 4], 16) catch continue;
                i += 4;
                break :blk v;
            },
            0xE2 => {
                // Escaped U+2028 or U+2029 is a line continuation.
                if (i + 1 < body.len and body[i] == 0x80 and (body[i + 1] == 0xA8 or body[i + 1] == 0xA9)) {
                    i += 2;
                    continue;
                }
                try flushSurrogate(allocator, &out, &pending_high);
                try out.append(allocator, e);
                continue;
            },
            else => {
                // Any other escaped character stands for itself; copy it byte by byte.
                try flushSurrogate(allocator, &out, &pending_high);
                try out.append(allocator, e);
                continue;
            },
        };
        try appendCodeUnit(allocator, &out, &pending_high, unit);
    }
    try flushSurrogate(allocator, &out, &pending_high);
    return out.toOwnedSlice(allocator);
}

/// Appends a code point, pairing a `😀` style surrogate pair into one code point.
fn appendCodeUnit(allocator: std.mem.Allocator, out: *std.ArrayList(u8), pending_high: *?u16, unit: u21) Error!void {
    if (unit >= 0xDC00 and unit <= 0xDFFF) {
        if (pending_high.*) |high| {
            pending_high.* = null;
            const code_point: u21 = 0x10000 + ((@as(u21, high) - 0xD800) << 10) + (unit - 0xDC00);
            return appendWtf8(allocator, out, code_point);
        }
    }
    try flushSurrogate(allocator, out, pending_high);
    if (unit >= 0xD800 and unit <= 0xDBFF) {
        pending_high.* = @intCast(unit);
        return;
    }
    try appendWtf8(allocator, out, unit);
}

fn flushSurrogate(allocator: std.mem.Allocator, out: *std.ArrayList(u8), pending_high: *?u16) Error!void {
    if (pending_high.*) |high| {
        pending_high.* = null;
        try appendWtf8(allocator, out, high);
    }
}

fn appendWtf8(allocator: std.mem.Allocator, out: *std.ArrayList(u8), code_point: u21) Error!void {
    var buffer: [4]u8 = undefined;
    const len = std.unicode.wtf8Encode(code_point, &buffer) catch unreachable;
    try out.appendSlice(allocator, buffer[0..len]);
}

// Tests

const testing = std.testing;

const Lexed = struct {
    source: Source,
    diagnostics: diagnostic.Diagnostics,
    tokens: []Token,

    fn init(input: []const u8) !*Lexed {
        const lexed = try testing.allocator.create(Lexed);
        lexed.source = try .init(testing.allocator, "test.ts", input);
        lexed.diagnostics = .init(testing.allocator);
        lexed.tokens = try tokenize(testing.allocator, &lexed.source, &lexed.diagnostics);
        return lexed;
    }

    fn deinit(this: *Lexed) void {
        testing.allocator.free(this.tokens);
        this.diagnostics.deinit();
        this.source.deinit(testing.allocator);
        testing.allocator.destroy(this);
    }

    fn expectTags(this: *Lexed, expected: []const Tag) !void {
        const actual = try testing.allocator.alloc(Tag, this.tokens.len);
        defer testing.allocator.free(actual);
        for (this.tokens, actual) |tok, *tag| tag.* = tok.tag;
        try testing.expectEqualSlices(Tag, expected, actual);
    }

    fn expectTexts(this: *Lexed, expected: []const []const u8) !void {
        try testing.expectEqual(expected.len + 1, this.tokens.len);
        for (expected, this.tokens[0..expected.len]) |want, tok| try testing.expectEqualStrings(want, tok.text(this.source.text));
    }

    fn expectCodes(this: *Lexed, expected: []const u16) !void {
        const actual = try testing.allocator.alloc(u16, this.diagnostics.items().len);
        defer testing.allocator.free(actual);
        for (this.diagnostics.items(), actual) |d, *code| code.* = d.code.number;
        try testing.expectEqualSlices(u16, expected, actual);
    }
};

fn expectTokens(input: []const u8, expected: []const Tag) !void {
    const lexed: *Lexed = try .init(input);
    defer lexed.deinit();
    try lexed.expectTags(expected);
    try lexed.expectCodes(&.{});
}

fn expectErrors(input: []const u8, expected: []const u16) !void {
    const lexed: *Lexed = try .init(input);
    defer lexed.deinit();
    try lexed.expectCodes(expected);
}

fn expectCooked(input: []const u8, expected: []const u8) !void {
    const lexed: *Lexed = try .init(input);
    defer lexed.deinit();
    try lexed.expectCodes(&.{});
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqualStrings(expected, try cook(arena.allocator(), lexed.source.text, lexed.tokens[0]));
}

test "empty input and trivia" {
    try expectTokens("", &.{.eof});
    try expectTokens("  \t// line\n/* block\n */ \u{FEFF}\u{A0}", &.{.eof});
    try expectTokens("#!/usr/bin/env zavascript\nx", &.{ .identifier, .eof });
}

test "identifiers and keywords" {
    try expectTokens("foo $bar _baz9 caf\u{E9}", &.{ .identifier, .identifier, .identifier, .identifier, .eof });
    try expectTokens("const let function return type as of", &.{ .kw_const, .kw_let, .kw_function, .kw_return, .identifier, .identifier, .identifier, .eof });
    try expectTokens("#secret", &.{ .private_name, .eof });
}

test "every punctuator" {
    const input = "{ } ( ) [ ] . ... ; , ? ?. ?? ??= : @ => < <= << <<= > = == === ! != !== + ++ += - -- -= * ** *= **= / /= % %= & && &= &&= | || |= ||= ^ ^= ~";
    const lexed: *Lexed = try .init(input);
    defer lexed.deinit();
    try lexed.expectCodes(&.{});
    var it = std.mem.tokenizeScalar(u8, input, ' ');
    var i: usize = 0;
    while (it.next()) |want| : (i += 1) {
        try testing.expectEqualStrings(want, lexed.tokens[i].tag.lexeme().?);
        try testing.expectEqualStrings(want, lexed.tokens[i].text(input));
    }
    try testing.expectEqual(Tag.eof, lexed.tokens[i].tag);
}

test "punctuators are longest match" {
    try expectTokens("a===b", &.{ .identifier, .equal_equal_equal, .identifier, .eof });
    try expectTokens("a**=b", &.{ .identifier, .star_star_equal, .identifier, .eof });
    try expectTokens("x?.y", &.{ .identifier, .question_dot, .identifier, .eof });
    // `?.` before a digit is a conditional followed by a number.
    try expectTokens("a?.5:1", &.{ .identifier, .question, .number, .colon, .number, .eof });
    // `>` is never combined, so nested type arguments close one at a time.
    try expectTokens("a>>=b>>>c>=d", &.{ .identifier, .greater, .greater, .equal, .identifier, .greater, .greater, .greater, .identifier, .greater, .equal, .identifier, .eof });
}

test "numbers" {
    const lexed: *Lexed = try .init("0 42 3.14 .5 5. 1e10 1E-7 2e+3 0x1F 0XaB 0o17 0b1010 1_000_000 0x_ff 10n 0x1Fn");
    defer lexed.deinit();
    try lexed.expectTexts(&.{ "0", "42", "3.14", ".5", "5.", "1e10", "1E-7", "2e+3", "0x1F", "0XaB", "0o17", "0b1010", "1_000_000", "0x_ff", "10n", "0x1Fn" });
    for (lexed.tokens[0..14]) |tok| if (!std.mem.eql(u8, tok.text(lexed.source.text), "0x_ff")) try testing.expectEqual(Tag.number, tok.tag);
    try testing.expectEqual(Tag.bigint, lexed.tokens[14].tag);
    try testing.expectEqual(Tag.bigint, lexed.tokens[15].tag);
    // `0x_ff` puts a separator right after the prefix.
    try lexed.expectCodes(&.{6188});
}

test "number errors" {
    try expectErrors("0x", &.{1125});
    try expectErrors("0b2", &.{1177});
    try expectErrors("0o", &.{1178});
    try expectErrors("1e", &.{1124});
    try expectErrors("1__0", &.{6189});
    try expectErrors("1_", &.{6188});
    try expectErrors("017", &.{1121});
    try expectErrors("019", &.{1489});
    try expectErrors("3in", &.{1351});
    try expectTokens("1", &.{ .number, .eof });
    try expectErrors("1.5n", &.{1351});
}

test "strings" {
    try expectTokens("'a' \"b\" '' \"it's\" 'say \"hi\"'", &.{ .string, .string, .string, .string, .string, .eof });
    try expectErrors("'abc", &.{1002});
    try expectErrors("'ab\nc'", &.{ 1002, 1002 });
    try expectErrors("'\\x4'", &.{1125});
    try expectErrors("'\\u12'", &.{1125});
    try expectErrors("'\\u{110000}'", &.{1198});
    try expectErrors("'\\u{41'", &.{1199});
    try expectErrors("'\\01'", &.{1487});
    try expectErrors("'\\8'", &.{1488});
}

test "cooked strings" {
    try expectCooked("'plain'", "plain");
    try expectCooked("'a\\nb\\tc\\\\d\\'e\\\"f'", "a\nb\tc\\d'e\"f");
    try expectCooked("'\\b\\f\\v\\0'", "\x08\x0C\x0B\x00");
    try expectCooked("'\\x41\\u0042\\u{43}\\u{1F600}'", "ABC\u{1F600}");
    try expectCooked("'\\uD83D\\uDE00'", "\u{1F600}");
    try expectCooked("'line\\\ncontinued'", "linecontinued");
    try expectCooked("'\\q\\€'", "q€");
    // A lone surrogate survives as WTF-8.
    try expectCooked("'\\uD800'", "\xED\xA0\x80");
}

test "templates" {
    try expectTokens("`plain`", &.{ .template_full, .eof });
    try expectTokens("`a${b}c`", &.{ .template_head, .identifier, .template_tail, .eof });
    try expectTokens("`a${b}c${d}e`", &.{ .template_head, .identifier, .template_middle, .identifier, .template_tail, .eof });
    // Braces inside a substitution don't end it.
    try expectTokens("`${ {a: 1}.a }`", &.{ .template_head, .l_brace, .identifier, .colon, .number, .r_brace, .dot, .identifier, .template_tail, .eof });
    // Templates nest inside substitutions.
    try expectTokens("`a${`b${c}d`}e`", &.{ .template_head, .template_head, .identifier, .template_tail, .template_tail, .eof });
    try expectTokens("`multi\nline`", &.{ .template_full, .eof });
    try expectErrors("`abc", &.{1160});
    try expectErrors("`a${b}c", &.{1160});
}

test "cooked templates" {
    try expectCooked("`a\\`b\\${c}`", "a`b${c}");
    try expectCooked("`one\r\ntwo\rthree`", "one\ntwo\nthree");
    try expectCooked("`x${", "x");
}

test "newline before" {
    const lexed: *Lexed = try .init("a\nb /* \n */ c /* */ d // x\ne");
    defer lexed.deinit();
    const expected = [_]bool{ false, true, true, false, true, false };
    for (expected, lexed.tokens) |want, tok| try testing.expectEqual(want, tok.newline_before);
}

test "invalid characters" {
    try expectErrors("a ¬ b", &.{1127});
    try expectErrors("#", &.{1127});
    try expectErrors("/* never closed", &.{1010});
    const lexed: *Lexed = try .init("a § b");
    defer lexed.deinit();
    try lexed.expectTags(&.{ .identifier, .invalid, .identifier, .eof });
}
