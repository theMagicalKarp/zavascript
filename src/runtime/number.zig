//! Conversions between numbers and strings with the exact behavior ECMA-262 specifies.

const std = @import("std");

/// Number::toString(x) with radix 10 (ECMA-262 §6.1.6.1.20): the shortest digits that round-trip,
/// switching to exponent notation outside 1e-7 < |x| < 1e21.
pub fn format(writer: *std.Io.Writer, x: f64) std.Io.Writer.Error!void {
    if (std.math.isNan(x)) {
        return writer.writeAll("NaN");
    }
    if (x == 0) {
        return writer.writeAll("0");
    }
    if (std.math.isInf(x)) {
        return writer.writeAll(if (x > 0) "Infinity" else "-Infinity");
    }
    if (x < 0) {
        try writer.writeByte('-');
        return format(writer, -x);
    }

    // Zig's `{e}` gives the shortest round-trip digits as `d.ddde±n`.
    var buffer: [64]u8 = undefined;
    const scientific = std.fmt.bufPrint(&buffer, "{e}", .{x}) catch unreachable;
    const e_index = std.mem.indexOfScalar(u8, scientific, 'e').?;
    var digit_buffer: [32]u8 = undefined;
    var k: usize = 0;
    for (scientific[0..e_index]) |c| {
        if (c == '.') {
            continue;
        }
        digit_buffer[k] = c;
        k += 1;
    }
    const digits = digit_buffer[0..k];
    // `n` is the spec's exponent: the value is 0.digits × 10^n.
    const n: i32 = (std.fmt.parseInt(i32, scientific[e_index + 1 ..], 10) catch unreachable) + 1;
    const k_int: i32 = @intCast(k);

    if (k_int <= n and n <= 21) {
        try writer.writeAll(digits);
        try writer.splatByteAll('0', @intCast(n - k_int));
    } else if (0 < n and n <= 21) {
        try writer.print("{s}.{s}", .{ digits[0..@intCast(n)], digits[@intCast(n)..] });
    } else if (-6 < n and n <= 0) {
        try writer.writeAll("0.");
        try writer.splatByteAll('0', @intCast(-n));
        try writer.writeAll(digits);
    } else {
        const exponent = n - 1;
        const sign: u8 = if (exponent < 0) '-' else '+';
        if (k == 1) {
            try writer.print("{s}e{c}{d}", .{ digits, sign, @abs(exponent) });
        } else {
            try writer.print("{c}.{s}e{c}{d}", .{ digits[0], digits[1..], sign, @abs(exponent) });
        }
    }
}

/// Formats into `allocator`, for building string values.
pub fn toString(allocator: std.mem.Allocator, x: f64) error{OutOfMemory}![]const u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    format(&out.writer, x) catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

/// The value of a numeric literal token, which the lexer has already validated. Separators are
/// allowed; `0x`, `0o` and `0b` prefixes select the radix.
pub fn parseLiteral(text: []const u8) f64 {
    var buffer: [128]u8 = undefined;
    var stripped: std.ArrayList(u8) = .initBuffer(&buffer);
    for (text) |c| {
        if (c == '_') {
            continue;
        }
        if (stripped.items.len == buffer.len) {
            return parseLongLiteral(text);
        }
        stripped.appendAssumeCapacity(c);
    }
    return parseStripped(stripped.items);
}

fn parseLongLiteral(text: []const u8) f64 {
    // Literals longer than the stack buffer are rare enough to round-trip through the heap.
    var arena_buffer: [4096]u8 = undefined;
    var fba: std.heap.FixedBufferAllocator = .init(&arena_buffer);
    const stripped = std.mem.replaceOwned(u8, fba.allocator(), text, "_", "") catch return std.math.nan(f64);
    return parseStripped(stripped);
}

fn parseStripped(text: []const u8) f64 {
    if (text.len > 2 and text[0] == '0') {
        const radix: ?u8 = switch (text[1]) {
            'x', 'X' => 16,
            'o', 'O' => 8,
            'b', 'B' => 2,
            else => null,
        };
        if (radix) |r| {
            return parseRadix(text[2..], r);
        }
    }
    return std.fmt.parseFloat(f64, text) catch std.math.nan(f64);
}

/// Integer digits in a power-of-two radix, rounded to the nearest f64 like the spec requires.
/// Once the value outgrows a u128, the low bits only matter as a "sticky" bit for rounding.
fn parseRadix(digits: []const u8, radix: u8) f64 {
    const bits_per_digit: u7 = std.math.log2_int(u8, radix);
    var value: u128 = 0;
    var dropped_bits: u32 = 0;
    var sticky = false;
    for (digits) |c| {
        const d = std.fmt.charToDigit(c, radix) catch return std.math.nan(f64);
        if (value >> (@as(u7, 127) - bits_per_digit + 1) == 0) {
            value = (value << bits_per_digit) | d;
        } else {
            sticky = sticky or d != 0;
            dropped_bits += bits_per_digit;
        }
    }
    if (sticky) {
        value |= 1;
    }
    const mantissa: f64 = @floatFromInt(value);
    if (dropped_bits > 1100) {
        return std.math.inf(f64);
    }
    return std.math.ldexp(mantissa, @intCast(dropped_bits));
}

/// StringToNumber (§7.1.4.1.1): what `Number(s)` and `+s` give. Surrounding whitespace is
/// ignored, an empty string is 0, and anything else that isn't a numeric literal is NaN. Unlike
/// source literals, separators and a trailing `n` aren't allowed.
pub fn parseString(s: []const u8) f64 {
    const trimmed = trimWhitespace(s);
    if (trimmed.len == 0) {
        return 0;
    }
    if (trimmed.len > 2 and trimmed[0] == '0') {
        const radix: ?u8 = switch (trimmed[1]) {
            'x', 'X' => 16,
            'o', 'O' => 8,
            'b', 'B' => 2,
            else => null,
        };
        if (radix) |r| {
            for (trimmed[2..]) |c| {
                _ = std.fmt.charToDigit(c, r) catch return std.math.nan(f64);
            }
            return parseRadix(trimmed[2..], r);
        }
    }
    var body = trimmed;
    var sign: f64 = 1;
    if (body[0] == '+' or body[0] == '-') {
        if (body[0] == '-') {
            sign = -1;
        }
        body = body[1..];
    }
    if (std.mem.eql(u8, body, "Infinity")) {
        return sign * std.math.inf(f64);
    }
    if (!isDecimalLiteral(body)) {
        return std.math.nan(f64);
    }
    return sign * (std.fmt.parseFloat(f64, body) catch return std.math.nan(f64));
}

/// StrUnsignedDecimalLiteral: digits with an optional fraction and exponent, at least one digit
/// before the exponent.
fn isDecimalLiteral(s: []const u8) bool {
    var i: usize = 0;
    var mantissa_digits: usize = 0;
    while (i < s.len and std.ascii.isDigit(s[i])) : (i += 1) {
        mantissa_digits += 1;
    }
    if (i < s.len and s[i] == '.') {
        i += 1;
        while (i < s.len and std.ascii.isDigit(s[i])) : (i += 1) {
            mantissa_digits += 1;
        }
    }
    if (mantissa_digits == 0) {
        return false;
    }
    if (i < s.len and (s[i] == 'e' or s[i] == 'E')) {
        i += 1;
        if (i < s.len and (s[i] == '+' or s[i] == '-')) {
            i += 1;
        }
        const exponent_start = i;
        while (i < s.len and std.ascii.isDigit(s[i])) {
            i += 1;
        }
        if (i == exponent_start) {
            return false;
        }
    }
    return i == s.len;
}

/// Strips the characters JS counts as whitespace or line terminators.
pub fn trimWhitespace(s: []const u8) []const u8 {
    var start: usize = 0;
    var end: usize = s.len;
    while (start < end) {
        const len = whitespaceAt(s[start..end]);
        if (len == 0) {
            break;
        }
        start += len;
    }
    outer: while (end > start) {
        // Whitespace is at most 3 bytes in UTF-8, so try each possible start.
        const longest: usize = @min(3, end - start);
        for (1..longest + 1) |len| {
            if (whitespaceAt(s[end - len .. end]) == len) {
                end -= len;
                continue :outer;
            }
        }
        break;
    }
    return s[start..end];
}

/// How many bytes of whitespace (or a line terminator) `s` starts with: one character's worth.
pub fn whitespaceAt(s: []const u8) usize {
    switch (s[0]) {
        ' ', '\t', '\n', '\r', 0x0B, 0x0C => return 1,
        else => {},
    }
    const len = std.unicode.utf8ByteSequenceLength(s[0]) catch return 0;
    if (len > s.len) {
        return 0;
    }
    const cp = std.unicode.utf8Decode(s[0..len]) catch return 0;
    return switch (cp) {
        0xA0, 0x1680, 0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF => len,
        else => 0,
    };
}

/// The shortest digits that round-trip `x` (positive and finite), and the exponent `n` that makes
/// the value 0.digits × 10^n.
fn shortestDigits(buffer: *[32]u8, x: f64) struct { []const u8, i32 } {
    var scratch: [64]u8 = undefined;
    const scientific = std.fmt.bufPrint(&scratch, "{e}", .{x}) catch unreachable;
    const e_index = std.mem.indexOfScalar(u8, scientific, 'e').?;
    var k: usize = 0;
    for (scientific[0..e_index]) |c| {
        if (c == '.') {
            continue;
        }
        buffer[k] = c;
        k += 1;
    }
    const n: i32 = (std.fmt.parseInt(i32, scientific[e_index + 1 ..], 10) catch unreachable) + 1;
    return .{ buffer[0..k], n };
}

const Big = std.math.big.int.Managed;

/// A positive finite double as the exact fraction `numerator / denominator`.
fn exactFraction(allocator: std.mem.Allocator, x: f64) error{OutOfMemory}!struct { Big, Big } {
    const bits: u64 = @bitCast(x);
    const biased: i32 = @intCast((bits >> 52) & 0x7FF);
    const fraction = bits & ((1 << 52) - 1);
    const mantissa: u64 = if (biased == 0) fraction else fraction | (1 << 52);
    const exponent: i32 = (if (biased == 0) 1 else biased) - 1075;
    var numerator = try Big.initSet(allocator, mantissa);
    var denominator = try Big.initSet(allocator, 1);
    if (exponent >= 0) {
        try numerator.shiftLeft(&numerator, @intCast(exponent));
    } else {
        try denominator.shiftLeft(&denominator, @intCast(-exponent));
    }
    return .{ numerator, denominator };
}

/// round(numerator × 10^scale / denominator), with a tie going up (the larger `n` the spec picks).
fn roundScaled(allocator: std.mem.Allocator, numerator: Big, denominator: Big, scale: i32) error{OutOfMemory}!Big {
    var num = try numerator.clone();
    var den = try denominator.clone();
    var ten = try Big.initSet(allocator, 10);
    var power = try Big.init(allocator);
    try power.pow(&ten, @abs(scale));
    if (scale >= 0) {
        try num.mul(&num, &power);
    } else {
        try den.mul(&den, &power);
    }
    // floor((2 × num + den) / (2 × den))
    try num.shiftLeft(&num, 1);
    try num.add(&num, &den);
    try den.shiftLeft(&den, 1);
    var quotient = try Big.init(allocator);
    var remainder = try Big.init(allocator);
    try quotient.divFloor(&remainder, &num, &den);
    return quotient;
}

fn bigDigits(allocator: std.mem.Allocator, n: Big) error{OutOfMemory}![]const u8 {
    return n.toString(allocator, 10, .lower) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => unreachable,
    };
}

/// Number.prototype.toFixed (§21.1.3.3) for `digits` in 0..100.
pub fn toFixed(allocator: std.mem.Allocator, x: f64, digits: u32) error{OutOfMemory}![]const u8 {
    if (!std.math.isFinite(x) or @abs(x) >= 1e21) {
        return toString(allocator, x);
    }
    var m: []const u8 = "0";
    if (x != 0) {
        const fraction = try exactFraction(allocator, @abs(x));
        m = try bigDigits(allocator, try roundScaled(allocator, fraction[0], fraction[1], @intCast(digits)));
    }
    var out: std.ArrayList(u8) = .empty;
    // `(-0).toFixed()` is "0", but `(-0.0001).toFixed(2)` is "-0.00".
    if (x < 0) {
        try out.append(allocator, '-');
    }
    if (digits == 0) {
        try out.appendSlice(allocator, m);
        return out.toOwnedSlice(allocator);
    }
    // At least one digit before the point.
    if (m.len <= digits) {
        const padded = try allocator.alloc(u8, digits + 1);
        @memset(padded[0 .. digits + 1 - m.len], '0');
        @memcpy(padded[digits + 1 - m.len ..], m);
        m = padded;
    }
    const integer_digits = m.len - digits;
    try out.appendSlice(allocator, m[0..integer_digits]);
    try out.append(allocator, '.');
    try out.appendSlice(allocator, m[integer_digits..]);
    return out.toOwnedSlice(allocator);
}

/// `p` significant digits of `|x|` (positive and finite), rounded with ties up, and the decimal
/// exponent of the first: `x ≈ d.ddd × 10^e`.
fn precisionDigits(allocator: std.mem.Allocator, x: f64, p: u32) error{OutOfMemory}!struct { []const u8, i32 } {
    const fraction = try exactFraction(allocator, x);
    var e: i32 = @intFromFloat(@floor(std.math.log10(x)));
    // The estimate can be off by one either way.
    var digits = try bigDigits(allocator, try roundScaled(allocator, fraction[0], fraction[1], @as(i32, @intCast(p)) - 1 - e));
    if (digits.len > p) {
        e += 1;
        digits = try bigDigits(allocator, try roundScaled(allocator, fraction[0], fraction[1], @as(i32, @intCast(p)) - 1 - e));
    } else if (digits.len < p) {
        e -= 1;
        digits = try bigDigits(allocator, try roundScaled(allocator, fraction[0], fraction[1], @as(i32, @intCast(p)) - 1 - e));
    }
    if (digits.len > p) {
        // Rounding up made it `10^p`.
        e += 1;
        digits = digits[0..p];
    }
    return .{ digits, e };
}

fn exponentPart(out: *std.ArrayList(u8), allocator: std.mem.Allocator, e: i32) error{OutOfMemory}!void {
    try out.print(allocator, "e{c}{d}", .{ @as(u8, if (e < 0) '-' else '+'), @abs(e) });
}

/// Number.prototype.toExponential (§21.1.3.2); null `digits` means as many as it takes.
pub fn toExponential(allocator: std.mem.Allocator, x: f64, digits: ?u32) error{OutOfMemory}![]const u8 {
    if (!std.math.isFinite(x)) {
        return toString(allocator, x);
    }
    var out: std.ArrayList(u8) = .empty;
    if (x < 0) {
        try out.append(allocator, '-');
    }
    var m: []const u8 = undefined;
    var e: i32 = 0;
    if (x == 0) {
        const zeros_ = try allocator.alloc(u8, (digits orelse 0) + 1);
        @memset(zeros_, '0');
        m = zeros_;
    } else if (digits) |f| {
        m, e = try precisionDigits(allocator, @abs(x), f + 1);
    } else {
        var buffer: [32]u8 = undefined;
        const shortest, const n = shortestDigits(&buffer, @abs(x));
        m = try allocator.dupe(u8, shortest);
        e = n - 1;
    }
    try out.append(allocator, m[0]);
    if (m.len > 1) {
        try out.append(allocator, '.');
        try out.appendSlice(allocator, m[1..]);
    }
    try exponentPart(&out, allocator, e);
    return out.toOwnedSlice(allocator);
}

/// Number.prototype.toPrecision (§21.1.3.5) for `p` in 1..100.
pub fn toPrecision(allocator: std.mem.Allocator, x: f64, p: u32) error{OutOfMemory}![]const u8 {
    if (!std.math.isFinite(x)) {
        return toString(allocator, x);
    }
    var out: std.ArrayList(u8) = .empty;
    if (x < 0) {
        try out.append(allocator, '-');
    }
    var m: []const u8 = undefined;
    var e: i32 = 0;
    if (x == 0) {
        const zeros_ = try allocator.alloc(u8, p);
        @memset(zeros_, '0');
        m = zeros_;
    } else {
        m, e = try precisionDigits(allocator, @abs(x), p);
    }
    const pi: i32 = @intCast(p);
    if (e < -6 or e >= pi) {
        try out.append(allocator, m[0]);
        if (p > 1) {
            try out.append(allocator, '.');
            try out.appendSlice(allocator, m[1..]);
        }
        try exponentPart(&out, allocator, e);
    } else if (e == pi - 1) {
        try out.appendSlice(allocator, m);
    } else if (e >= 0) {
        const point: usize = @intCast(e + 1);
        try out.appendSlice(allocator, m[0..point]);
        try out.append(allocator, '.');
        try out.appendSlice(allocator, m[point..]);
    } else {
        try out.appendSlice(allocator, "0.");
        try out.appendNTimes(allocator, '0', @intCast(-(e + 1)));
        try out.appendSlice(allocator, m);
    }
    return out.toOwnedSlice(allocator);
}

/// Number.prototype.toString with a radix other than 10, the way V8 does it
/// (`DoubleToRadixCString`): the fraction gets only as many digits as the double's precision
/// has, rounded to even.
pub fn toRadix(allocator: std.mem.Allocator, x: f64, radix: u8) error{OutOfMemory}![]const u8 {
    if (radix == 10 or !std.math.isFinite(x) or x == 0) {
        return toString(allocator, x);
    }
    const chars = "0123456789abcdefghijklmnopqrstuvwxyz";
    const size = 2200;
    var buffer: [size]u8 = undefined;
    var integer_cursor: usize = size / 2;
    var fraction_cursor: usize = integer_cursor;
    const negative = x < 0;
    const v = @abs(x);
    const r: f64 = @floatFromInt(radix);
    var integer = @floor(v);
    var fraction = v - integer;
    var delta = 0.5 * (std.math.nextAfter(f64, v, std.math.inf(f64)) - v);
    delta = @max(std.math.nextAfter(f64, 0.0, 1.0), delta);
    if (fraction >= delta) {
        buffer[fraction_cursor] = '.';
        fraction_cursor += 1;
        while (true) {
            fraction *= r;
            delta *= r;
            const digit: usize = @intFromFloat(fraction);
            buffer[fraction_cursor] = chars[digit];
            fraction_cursor += 1;
            fraction -= @floatFromInt(digit);
            if (fraction > 0.5 or (fraction == 0.5 and (digit & 1) == 1)) {
                if (fraction + delta > 1) {
                    // Round up, carrying through the digits already written.
                    while (true) {
                        fraction_cursor -= 1;
                        if (fraction_cursor == size / 2) {
                            integer += 1;
                            break;
                        }
                        const c = buffer[fraction_cursor];
                        const d: usize = if (c > '9') c - 'a' + 10 else c - '0';
                        if (d + 1 < radix) {
                            buffer[fraction_cursor] = chars[d + 1];
                            fraction_cursor += 1;
                            break;
                        }
                    }
                    break;
                }
            }
            if (!(fraction >= delta)) {
                break;
            }
        }
    }
    // Digits past the double's precision are zeros.
    while (integer / r >= 9007199254740992.0) {
        integer /= r;
        integer_cursor -= 1;
        buffer[integer_cursor] = '0';
    }
    while (true) {
        const remainder = @mod(integer, r);
        integer_cursor -= 1;
        buffer[integer_cursor] = chars[@intFromFloat(remainder)];
        integer = (integer - remainder) / r;
        if (!(integer > 0)) {
            break;
        }
    }
    if (negative) {
        integer_cursor -= 1;
        buffer[integer_cursor] = '-';
    }
    return allocator.dupe(u8, buffer[integer_cursor..fraction_cursor]);
}

/// parseInt (§19.2.5) of a string, with `radix` already ToInt32'd.
pub fn parseInt(s: []const u8, radix_given: i32) f64 {
    var rest = trimStart(s);
    var sign: f64 = 1;
    if (rest.len > 0 and (rest[0] == '+' or rest[0] == '-')) {
        if (rest[0] == '-') {
            sign = -1;
        }
        rest = rest[1..];
    }
    var radix = radix_given;
    var strip_prefix = true;
    if (radix != 0) {
        if (radix < 2 or radix > 36) {
            return std.math.nan(f64);
        }
        if (radix != 16) {
            strip_prefix = false;
        }
    } else {
        radix = 10;
    }
    if (strip_prefix and rest.len >= 2 and rest[0] == '0' and (rest[1] == 'x' or rest[1] == 'X')) {
        rest = rest[2..];
        radix = 16;
    }
    const r: u8 = @intCast(radix);
    var end: usize = 0;
    while (end < rest.len) : (end += 1) {
        _ = std.fmt.charToDigit(rest[end], r) catch break;
    }
    const digits = rest[0..end];
    if (digits.len == 0) {
        return std.math.nan(f64);
    }
    const magnitude = switch (r) {
        10 => std.fmt.parseFloat(f64, digits) catch unreachable,
        2, 4, 8, 16, 32 => parseRadix(digits, r),
        else => blk: {
            var n: f64 = 0;
            for (digits) |c| {
                n = n * @as(f64, @floatFromInt(r)) + @as(f64, @floatFromInt(std.fmt.charToDigit(c, r) catch unreachable));
            }
            break :blk n;
        },
    };
    return sign * magnitude;
}

/// parseFloat (§19.2.4): the longest prefix (after whitespace) that's a decimal literal.
pub fn parseFloat(s: []const u8) f64 {
    const rest = trimStart(s);
    var i: usize = 0;
    var sign: f64 = 1;
    if (i < rest.len and (rest[i] == '+' or rest[i] == '-')) {
        if (rest[i] == '-') {
            sign = -1;
        }
        i += 1;
    }
    if (std.mem.startsWith(u8, rest[i..], "Infinity")) {
        return sign * std.math.inf(f64);
    }
    const start = i;
    var mantissa_digits: usize = 0;
    while (i < rest.len and std.ascii.isDigit(rest[i])) : (i += 1) {
        mantissa_digits += 1;
    }
    if (i < rest.len and rest[i] == '.') {
        const point = i;
        i += 1;
        var fraction_digits: usize = 0;
        while (i < rest.len and std.ascii.isDigit(rest[i])) : (i += 1) {
            fraction_digits += 1;
        }
        mantissa_digits += fraction_digits;
        if (fraction_digits == 0) {
            i = point + 1;
        }
    }
    if (mantissa_digits == 0) {
        return std.math.nan(f64);
    }
    var end = i;
    if (i < rest.len and (rest[i] == 'e' or rest[i] == 'E')) {
        var j = i + 1;
        if (j < rest.len and (rest[j] == '+' or rest[j] == '-')) {
            j += 1;
        }
        const exponent_start = j;
        while (j < rest.len and std.ascii.isDigit(rest[j])) {
            j += 1;
        }
        if (j > exponent_start) {
            end = j;
        }
    }
    var text = rest[start..end];
    if (text[text.len - 1] == '.') {
        text = text[0 .. text.len - 1];
    }
    return sign * (std.fmt.parseFloat(f64, text) catch std.math.nan(f64));
}

fn trimStart(s: []const u8) []const u8 {
    var start: usize = 0;
    while (start < s.len) {
        const len = whitespaceAt(s[start..]);
        if (len == 0) {
            break;
        }
        start += len;
    }
    return s[start..];
}

fn expectFormat(expected: []const u8, x: f64) !void {
    var buffer: [64]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try format(&writer, x);
    try std.testing.expectEqualStrings(expected, writer.buffered());
}

test format {
    try expectFormat("0", 0);
    try expectFormat("0", -0.0);
    try expectFormat("NaN", std.math.nan(f64));
    try expectFormat("Infinity", std.math.inf(f64));
    try expectFormat("-Infinity", -std.math.inf(f64));
    try expectFormat("1", 1);
    try expectFormat("-42", -42);
    try expectFormat("123.456", 123.456);
    try expectFormat("100", 100);
    var a: f64 = 0.1;
    _ = &a;
    try expectFormat("0.30000000000000004", a + 0.2);
    try expectFormat("0.000001", 0.000001);
    try expectFormat("1e-7", 1e-7);
    try expectFormat("1.5e-7", 1.5e-7);
    try expectFormat("100000000000000000000", 1e20);
    try expectFormat("1e+21", 1e21);
    try expectFormat("1.2345e+21", 1.2345e21);
    try expectFormat("5e-324", 5e-324);
    try expectFormat("1.7976931348623157e+308", std.math.floatMax(f64));
    try expectFormat("9007199254740992", 9007199254740992);
    try expectFormat("0.1", 0.1);
}

test parseLiteral {
    try std.testing.expectEqual(@as(f64, 1_000_000), parseLiteral("1_000_000"));
    try std.testing.expectEqual(@as(f64, 255), parseLiteral("0xFF"));
    try std.testing.expectEqual(@as(f64, 255), parseLiteral("0Xf_f"));
    try std.testing.expectEqual(@as(f64, 15), parseLiteral("0o17"));
    try std.testing.expectEqual(@as(f64, 10), parseLiteral("0b1010"));
    try std.testing.expectEqual(@as(f64, 0.5), parseLiteral(".5"));
    try std.testing.expectEqual(@as(f64, 5), parseLiteral("5."));
    try std.testing.expectEqual(@as(f64, 2.5e-3), parseLiteral("2.5e-3"));
    try std.testing.expectEqual(std.math.inf(f64), parseLiteral("1e400"));
    // 2^53 + 1 isn't representable and rounds to even.
    try std.testing.expectEqual(@as(f64, 9007199254740992), parseLiteral("0x20000000000001"));
    // Past 128 bits the dropped digits still round correctly: exactly half an ulp rounds to even,
    // and anything more rounds up.
    const two_140 = std.math.ldexp(@as(f64, 1), 140);
    try std.testing.expectEqual(two_140, parseLiteral("0x1" ++ zeros(35)));
    try std.testing.expectEqual(two_140, parseLiteral("0x1" ++ zeros(12) ++ "08" ++ zeros(21)));
    try std.testing.expectEqual(two_140 + std.math.ldexp(@as(f64, 1), 88), parseLiteral("0x1" ++ zeros(12) ++ "08" ++ zeros(20) ++ "1"));
    try std.testing.expectEqual(std.math.inf(f64), parseLiteral("0x1" ++ zeros(300)));
}

test parseString {
    try std.testing.expectEqual(@as(f64, 0), parseString(""));
    try std.testing.expectEqual(@as(f64, 0), parseString("  \n\t"));
    try std.testing.expectEqual(@as(f64, 42), parseString(" 42 "));
    try std.testing.expectEqual(@as(f64, -1.5), parseString("-1.5"));
    try std.testing.expectEqual(@as(f64, 0.5), parseString(".5"));
    try std.testing.expectEqual(@as(f64, 5), parseString("5."));
    try std.testing.expectEqual(@as(f64, 1000), parseString("1e3"));
    try std.testing.expectEqual(@as(f64, 255), parseString("0xff"));
    try std.testing.expectEqual(std.math.inf(f64), parseString("Infinity"));
    try std.testing.expectEqual(-std.math.inf(f64), parseString("-Infinity"));
    try std.testing.expectEqual(@as(f64, 7), parseString("\u{A0}7\u{3000}"));
    for ([_][]const u8{ "abc", "1_000", "0x", "-0x1", "1e", "inf", "nan", ".", "1n", "--1", "1 2" }) |bad| {
        try std.testing.expect(std.math.isNan(parseString(bad)));
    }
}

fn zeros(comptime n: usize) *const [n]u8 {
    const result: [n]u8 = @splat('0');
    return &result;
}
