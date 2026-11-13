//! The builtins: what `lib.d.ts` declares, implemented natively. Globals are installed in the
//! interpreter; prototypes are tables the interpreter looks a property up in when the value
//! doesn't have it. A test below checks that everything `lib.d.ts` declares is here, and the
//! other way round.

const std = @import("std");
const value = @import("value.zig");
const Interpreter = @import("Interpreter.zig");
const Value = value.Value;

pub const native = @import("builtins/native.zig");
pub const arrays = @import("builtins/arrays.zig");
pub const collections = @import("builtins/collections.zig");
pub const console = @import("builtins/console.zig");
pub const errors = @import("builtins/errors.zig");
pub const iterators = @import("builtins/iterators.zig");
pub const json = @import("builtins/json.zig");
pub const math = @import("builtins/math.zig");
pub const numbers = @import("builtins/numbers.zig");
pub const objects = @import("builtins/objects.zig");
pub const strings = @import("builtins/strings.zig");

/// What the builtins keep between calls.
pub const State = struct {
    console: console.State = .{},
    random: std.Random.DefaultPrng = .init(0),
    /// The last long string `String.prototype` methods converted to code units.
    text: strings.Text = .{ .bytes = "", .units = null },
    /// The last long string `length` was asked of, and its length in code units.
    length: struct { bytes: []const u8 = "", units: usize = 0 } = .{},
};

/// A namespace object like `Math`, whose members aren't enumerable.
fn namespace(it: *Interpreter, tag: []const u8, members: *const value.Table) error{OutOfMemory}!Value {
    const o = try it.arena.create(value.Object);
    o.* = .{ .tag = tag, .methods = members };
    return .{ .object = o };
}

pub fn install(it: *Interpreter) error{OutOfMemory}!void {
    const globals = [_]struct { []const u8, Value }{
        .{ "undefined", .undefined },
        .{ "NaN", native.number(std.math.nan(f64)) },
        .{ "Infinity", native.number(std.math.inf(f64)) },
        .{ "console", console.create(it) catch return error.OutOfMemory },
        .{ "Math", try namespace(it, "Object [Math]", &math.members) },
        .{ "JSON", try namespace(it, "Object [JSON]", &json.members) },
        .{ "Number", numbers.constructor },
        .{ "Boolean", numbers.boolean_constructor },
        .{ "String", strings.constructor },
        .{ "Object", objects.constructor },
        .{ "Array", arrays.constructor },
        .{ "Map", collections.map_constructor },
        .{ "Set", collections.set_constructor },
        .{ "parseInt", numbers.parse_int },
        .{ "parseFloat", numbers.parse_float },
        .{ "isNaN", numbers.is_nan },
        .{ "isFinite", numbers.is_finite },
    };
    for (globals) |g| {
        try it.globals.put(it.arena, g[0], g[1]);
    }
    for (errors.constructors) |c| {
        try it.globals.put(it.arena, c.native_function.name, c);
    }
}

/// Properties JavaScript has that we don't implement yet, by what has them. Reading one through
/// `any` is unsupported rather than quietly `undefined`.
const unimplemented_properties = struct {
    const array = [_][]const u8{ "toLocaleString", "copyWithin", "findLast", "findLastIndex", "toReversed", "toSorted", "toSpliced", "with" };
    const string = [_][]const u8{
        "localeCompare", "match",  "matchAll", "search", "normalize", "toLocaleLowerCase", "toLocaleUpperCase", "isWellFormed", "toWellFormed",
        "anchor",        "big",    "blink",    "bold",   "fixed",     "fontcolor",         "fontsize",          "italics",      "link",
        "small",         "strike", "sub",      "sup",
    };
    const number = [_][]const u8{"toLocaleString"};
    const object = [_][]const u8{ "constructor", "toLocaleString", "isPrototypeOf", "propertyIsEnumerable", "__proto__", "__defineGetter__", "__defineSetter__", "__lookupGetter__", "__lookupSetter__" };
};

pub fn unimplemented(object: Value, name: []const u8) bool {
    const lists: []const []const []const u8 = switch (object) {
        .array => &.{ &unimplemented_properties.array, &unimplemented_properties.object },
        .string => &.{ &unimplemented_properties.string, &unimplemented_properties.object },
        .number => &.{ &unimplemented_properties.number, &unimplemented_properties.object },
        else => &.{&unimplemented_properties.object},
    };
    for (lists) |list| {
        for (list) |n| {
            if (std.mem.eql(u8, n, name)) {
                return true;
            }
        }
    }
    return false;
}

const testing = std.testing;
const ast = @import("../syntax/ast.zig");

/// What `lib.d.ts` declares, for checking it against what's implemented.
const Library = struct {
    program: ast.Program,

    fn interface(this: Library, name: []const u8) ?*const ast.Interface {
        for (this.program.statements) |stmt| {
            if (stmt.data == .interface and std.mem.eql(u8, stmt.data.interface.name, name)) {
                return stmt.data.interface;
            }
        }
        return null;
    }

    /// The names of an interface's members (not its signatures), with those it inherits.
    fn members(this: Library, arena: std.mem.Allocator, name: []const u8) ![]const []const u8 {
        const i = this.interface(name) orelse return error.MissingInterface;
        var list: std.ArrayList([]const u8) = .empty;
        for (i.extends) |base| {
            try list.appendSlice(arena, try this.members(arena, base.name));
        }
        for (i.members) |m| {
            if (m.signature == .none) {
                try list.append(arena, m.name);
            }
        }
        return list.items;
    }

    fn has(this: Library, arena: std.mem.Allocator, interface_name: []const u8, member: []const u8) !bool {
        for (try this.members(arena, interface_name)) |m| {
            if (std.mem.eql(u8, m, member)) {
                return true;
            }
        }
        return false;
    }

    fn signatures(this: Library, name: []const u8, kind: std.meta.Tag(ast.TypeMember.Signature)) usize {
        const i = this.interface(name) orelse return 0;
        var n: usize = 0;
        for (i.members) |m| {
            if (m.signature == kind) {
                n += 1;
            }
        }
        return n;
    }
};

fn parseLibrary(arena: std.mem.Allocator) !Library {
    const Source = @import("../Source.zig");
    const diagnostic = @import("../diagnostic.zig");
    const source = try arena.create(Source);
    source.* = try .init(arena, "lib.d.ts", @embedFile("../lib/lib.d.ts"));
    var diagnostics: diagnostic.Diagnostics = .init(testing.allocator);
    defer diagnostics.deinit();
    const program = try @import("../syntax/Parser.zig").parse(testing.allocator, arena, source, &diagnostics);
    try testing.expectEqual(0, diagnostics.items().len);
    return .{ .program = program };
}

/// Fails with a message naming what's missing.
fn expectIn(comptime what: []const u8, name: []const u8, found: bool) !void {
    if (!found) {
        std.debug.print(what ++ ": {s}\n", .{name});
        return error.TestExpectedEqual;
    }
}

/// Every name in `table` is a member of one of `interfaces`, and (unless `partial`) every member
/// of the first interface but `skip` is in `table`.
fn expectMatches(arena: std.mem.Allocator, library: Library, table: *const value.Table, interfaces: []const []const u8, skip: []const []const u8) !void {
    for (table.keys()) |name| {
        var declared = false;
        for (interfaces) |i| {
            declared = declared or try library.has(arena, i, name);
        }
        try expectIn("implemented but not declared", try std.fmt.allocPrint(arena, "{s}.{s}", .{ interfaces[0], name }), declared);
    }
    for (try library.members(arena, interfaces[0])) |name| {
        const skipped = for (skip) |s| {
            if (std.mem.eql(u8, s, name)) {
                break true;
            }
        } else false;
        if (!skipped) {
            try expectIn("declared but not implemented", try std.fmt.allocPrint(arena, "{s}.{s}", .{ interfaces[0], name }), table.has(name));
        }
    }
}

test "everything lib.d.ts declares is implemented, and nothing else" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const library = try parseLibrary(arena);
    var out: std.Io.Writer.Allocating = .init(arena);
    var it = try Interpreter.init(arena, &out.writer, &out.writer, 1 << 20, 0);

    // The globals, and the members of each.
    var declared: std.StringHashMapUnmanaged(void) = .empty;
    for (library.program.statements) |stmt| {
        if (stmt.data != .declare) {
            continue;
        }
        const d = stmt.data.declare;
        try declared.put(arena, d.name, {});
        const global = it.globals.get(d.name);
        try expectIn("declared but not a global", d.name, global != null);
        if (d.function) {
            try expectIn("declared a function but isn't one", d.name, global.? == .native_function);
            continue;
        }
        if (d.type.data != .reference) {
            continue;
        }
        const interface = d.type.data.reference.name;
        switch (global.?) {
            .native_function => |f| {
                // An error's `prototype` isn't an object we have.
                try expectMatches(arena, library, f.statics.?, &.{interface}, &.{"prototype"});
                try expectIn("callable but not declared so, or the other way round", d.name, (library.signatures(interface, .call) > 0) == (f.call != null));
                try expectIn("constructable but not declared so, or the other way round", d.name, (library.signatures(interface, .construct) > 0) == (f.construct != null));
            },
            .object => |o| if (o.methods) |methods| {
                try expectMatches(arena, library, methods, &.{interface}, &.{});
            } else {
                // `console`, whose methods are its own properties.
                for (try library.members(arena, interface)) |name| {
                    try expectIn("declared but not implemented", name, o.properties.contains(name));
                }
                for (o.properties.keys()) |name| {
                    try expectIn("implemented but not declared", name, try library.has(arena, interface, name));
                }
            },
            else => {},
        }
    }
    var globals = it.globals.keyIterator();
    while (globals.next()) |name| {
        try expectIn("a global but not declared", name.*, std.mem.eql(u8, name.*, "undefined") or declared.contains(name.*));
    }

    // The prototypes. A primitive's also has what `Object`'s does, and a few members (like an
    // array's `length`) aren't methods, so the interpreter has them itself.
    try expectMatches(arena, library, &arrays.methods, &.{"Array"}, &.{"length"});
    try expectMatches(arena, library, &arrays.methods, &.{ "ReadonlyArray", "Array" }, &.{"length"});
    try expectMatches(arena, library, &strings.methods, &.{ "String", "Object" }, &.{"length"});
    try expectMatches(arena, library, &numbers.methods, &.{ "Number", "Object" }, &.{});
    try expectMatches(arena, library, &numbers.boolean_methods, &.{ "Boolean", "Object" }, &.{});
    try expectMatches(arena, library, &objects.prototype, &.{"Object"}, &.{});
    try expectMatches(arena, library, &collections.map_methods, &.{"Map"}, &.{"size"});
    try expectMatches(arena, library, &collections.map_methods, &.{ "ReadonlyMap", "Map" }, &.{"size"});
    try expectMatches(arena, library, &collections.set_methods, &.{"Set"}, &.{"size"});
    try expectMatches(arena, library, &collections.set_methods, &.{ "ReadonlySet", "Set" }, &.{"size"});
    try expectMatches(arena, library, &errors.methods, &.{ "Error", "Object" }, &.{ "name", "message", "stack", "cause" });
    for ([_][]const u8{ "ArrayIterator", "MapIterator", "SetIterator", "StringIterator" }) |name| {
        try expectMatches(arena, library, &iterators.methods, &.{name}, &.{});
    }
}
