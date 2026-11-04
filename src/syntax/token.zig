const std = @import("std");

pub const Token = struct {
    tag: Tag,
    /// Byte span in the source.
    start: u32,
    end: u32,
    /// A line terminator came between the previous token and this one, which drives automatic
    /// semicolon insertion and the "no line terminator here" rules.
    newline_before: bool = false,

    pub fn text(this: Token, source: []const u8) []const u8 {
        return source[this.start..this.end];
    }
};

pub const Tag = enum {
    eof,
    /// A character that can't start any token; already reported by the lexer.
    invalid,

    identifier,
    /// `#name`
    private_name,
    number,
    /// `123n`
    bigint,
    string,
    /// `` `text` `` with no substitutions.
    template_full,
    /// `` `text${ ``
    template_head,
    /// `}text${`
    template_middle,
    /// `` }text` ``
    template_tail,

    // Punctuators.
    l_brace,
    r_brace,
    l_paren,
    r_paren,
    l_bracket,
    r_bracket,
    dot,
    ellipsis,
    semicolon,
    comma,
    question,
    question_dot,
    question_question,
    question_question_equal,
    colon,
    at,
    arrow,
    less,
    less_equal,
    less_less,
    less_less_equal,
    /// Always a lone `>`: `>=`, `>>`, `>>>` and their assignment forms are put back together by the
    /// parser from adjacent `>` and `=` tokens, so that `Array<Array<number>>` closes two type
    /// argument lists. This is how tsc does it too.
    greater,
    equal,
    equal_equal,
    equal_equal_equal,
    bang,
    bang_equal,
    bang_equal_equal,
    plus,
    plus_plus,
    plus_equal,
    minus,
    minus_minus,
    minus_equal,
    star,
    star_star,
    star_equal,
    star_star_equal,
    slash,
    slash_equal,
    percent,
    percent_equal,
    ampersand,
    ampersand_ampersand,
    ampersand_equal,
    ampersand_ampersand_equal,
    pipe,
    pipe_pipe,
    pipe_equal,
    pipe_pipe_equal,
    caret,
    caret_equal,
    tilde,

    // Reserved words. Contextual keywords like `type`, `as` and `of` are plain identifiers that the
    // parser recognizes by their text, since they're valid variable names.
    kw_await,
    kw_break,
    kw_case,
    kw_catch,
    kw_class,
    kw_const,
    kw_continue,
    kw_debugger,
    kw_default,
    kw_delete,
    kw_do,
    kw_else,
    kw_enum,
    kw_export,
    kw_extends,
    kw_false,
    kw_finally,
    kw_for,
    kw_function,
    kw_if,
    kw_implements,
    kw_import,
    kw_in,
    kw_instanceof,
    kw_interface,
    kw_let,
    kw_new,
    kw_null,
    kw_package,
    kw_private,
    kw_protected,
    kw_public,
    kw_return,
    kw_static,
    kw_super,
    kw_switch,
    kw_this,
    kw_throw,
    kw_true,
    kw_try,
    kw_typeof,
    kw_var,
    kw_void,
    kw_while,
    kw_with,
    kw_yield,

    pub fn isKeyword(this: Tag) bool {
        return @backingInt(this) >= @backingInt(Tag.kw_await);
    }

    /// The token's fixed spelling, or null for tokens whose text varies.
    pub fn lexeme(this: Tag) ?[]const u8 {
        return switch (this) {
            .eof, .invalid, .identifier, .private_name, .number, .bigint, .string => null,
            .template_full, .template_head, .template_middle, .template_tail => null,
            .l_brace => "{",
            .r_brace => "}",
            .l_paren => "(",
            .r_paren => ")",
            .l_bracket => "[",
            .r_bracket => "]",
            .dot => ".",
            .ellipsis => "...",
            .semicolon => ";",
            .comma => ",",
            .question => "?",
            .question_dot => "?.",
            .question_question => "??",
            .question_question_equal => "??=",
            .colon => ":",
            .at => "@",
            .arrow => "=>",
            .less => "<",
            .less_equal => "<=",
            .less_less => "<<",
            .less_less_equal => "<<=",
            .greater => ">",
            .equal => "=",
            .equal_equal => "==",
            .equal_equal_equal => "===",
            .bang => "!",
            .bang_equal => "!=",
            .bang_equal_equal => "!==",
            .plus => "+",
            .plus_plus => "++",
            .plus_equal => "+=",
            .minus => "-",
            .minus_minus => "--",
            .minus_equal => "-=",
            .star => "*",
            .star_star => "**",
            .star_equal => "*=",
            .star_star_equal => "**=",
            .slash => "/",
            .slash_equal => "/=",
            .percent => "%",
            .percent_equal => "%=",
            .ampersand => "&",
            .ampersand_ampersand => "&&",
            .ampersand_equal => "&=",
            .ampersand_ampersand_equal => "&&=",
            .pipe => "|",
            .pipe_pipe => "||",
            .pipe_equal => "|=",
            .pipe_pipe_equal => "||=",
            .caret => "^",
            .caret_equal => "^=",
            .tilde => "~",
            else => @tagName(this)[3..],
        };
    }
};

pub const keywords: std.StaticStringMap(Tag) = blk: {
    const names = @typeInfo(Tag).@"enum".field_names;
    var entries: [names.len]struct { []const u8, Tag } = undefined;
    var n = 0;
    for (names) |name| {
        if (std.mem.startsWith(u8, name, "kw_")) {
            entries[n] = .{ name[3..], @field(Tag, name) };
            n += 1;
        }
    }
    break :blk .initComptime(entries[0..n]);
};

test keywords {
    try std.testing.expectEqual(Tag.kw_function, keywords.get("function").?);
    try std.testing.expectEqual(Tag.kw_yield, keywords.get("yield").?);
    try std.testing.expectEqual(null, keywords.get("type"));
    try std.testing.expectEqualStrings("instanceof", Tag.kw_instanceof.lexeme().?);
}
