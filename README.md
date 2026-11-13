# zavascript

A small TypeScript runtime written in Zig. It type checks your program the way
`tsc --strict` does, refuses to run it if there are errors, and then runs it
with its own interpreter. There's no JavaScript engine underneath.

```console
$ cat hello.ts
console.log(`0.1 + 0.2 = ${0.1 + 0.2}`);
console.log("total: " + 2 * 21);

$ zavascript hello.ts
0.1 + 0.2 = 0.30000000000000004
total: 42

$ echo 'console.log("a" * 2)' | zavascript
<stdin>(1,13): error TS2362: The left-hand side of an arithmetic operation must be of type 'any', 'number', 'bigint' or an enum type.
```

> [!NOTE]
> zavascript is early. Today it runs `let` and `const`, every operator
> including assignment, `in`, `delete`, optional chaining and `??`, `if`, the
> loops (including `for...of` over arrays, strings, maps, sets and iterators,
> and `for...in`), `switch`, labeled `break`/`continue`, `throw` and
> `try`/`catch`/`finally`, functions (declarations, expressions and arrows,
> with closures, default, optional and rest parameters, spread arguments, and
> recursion), object and array literals
> (with shorthand, computed keys, methods and spread), and destructuring with
> defaults and rest in declarations and parameters. The checker covers
> primitive, literal, union, array, tuple, object and function types,
> interfaces (with `extends`, call, construct and index signatures) and type
> aliases, optional and `readonly` properties, structural assignability with
> tsc's excess and missing property checks, definite assignment, contextual
> typing, `as`, `as const`, `satisfies` and `!`, and tsc's narrowing: by
> assignment, truthiness, `===`/`==`, `typeof`, `in`, discriminant properties,
> `switch`, control flow, and type guards (written as `x is T`, or inferred
> the way tsc 5.5 does, so `xs.filter((x) => x !== null)` narrows), and
> `instanceof`. A `catch` binding is `unknown`, as under `strict`. Generic
> functions, interfaces and type aliases work too, with constraints, defaults,
> explicit type arguments and tsc's inference, as do `keyof`, indexed access
> types, `typeof` in types, mapped types, `readonly` arrays, `Partial`,
> `Required`, `Readonly`, `Pick` and `Record`.
>
> The builtins are declared in [`lib.d.ts`](src/lib/lib.d.ts), following
> TypeScript's ES2022 library (overloads and all), and implemented natively:
> `Array.prototype`, `String.prototype` (with UTF-16 indices), `Math` (with
> V8's fdlibm results), `Number`, `Boolean`, `Object` (`keys`, `values`,
> `entries`, `assign`, `freeze`, `fromEntries`, `hasOwn`), `JSON`, `Map`,
> `Set`, their iterators, `Error` and its subclasses (which the runtime's own
> `TypeError`s and `RangeError`s are, so they can be caught), and `console`
> (`log` and friends with format specifiers, `group`, `count`, `assert`,
> `dir`), all printing the way node does. An uncaught exception is reported the way node reports it, with a
> stack trace, and exits with 1. Classes are coming. Anything not supported
> yet, like `Date` or `RegExp`, is a compile error (`ZV9001`), never a silent
> misbehavior.

## Usage

Tools are managed with [mise](https://mise.jdx.dev): `mise install` gets Zig,
plus node and TypeScript for the oracle.

```sh
mise run build              # zig-out/bin/zavascript
mise run run -- file.ts     # type check and run a file
mise run run -- --check f.ts  # type check only
mise run repl               # interactive REPL
```

| Task                      | What it does                                                      |
| ------------------------- | ----------------------------------------------------------------- |
| `mise run test`           | Zig unit tests, then every conformance case in `tests/cases`      |
| `mise run oracle`         | Checks the conformance expectations against real `tsc` and `node` |
| `mise run bench`          | Times each `bench/cases` program per phase, vs. the baseline      |
| `mise run bench:baseline` | Saves the last benchmark run as the baseline                      |
| `mise run check`          | Everything CI runs: tests, formatting and the oracle              |

## Using it as a library

```sh
zig fetch --save git+https://github.com/theMagicalKarp/zavascript
```

```zig
// build.zig
const zavascript = b.dependency("zavascript", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("zavascript", zavascript.module("zavascript"));
```

```zig
const zavascript = @import("zavascript");

var runtime: zavascript.Runtime = try .init(gpa, .{ .stdout = stdout, .stderr = stderr });
defer runtime.deinit();

const result = runtime.run("rule.ts", source) catch |err| switch (err) {
    error.CompileError => {
        try runtime.diagnostics.render(stderr); // tsc-style, one per line
        return err;
    },
    error.RuntimeError => {
        try runtime.exception().?.render(stderr); // as node reports an uncaught exception
        return err;
    },
    else => return err,
};
```

Output from `console` goes to the writers you pass in. Reading exports, calling
functions and binding host functions and `.d.ts` declarations are planned.

## Tests

A conformance case is an ordinary TypeScript file with its expectations in
comments:

```ts
console.log(1 + 2 * 3); //> 7
console.log("a" * 2); //! TS2362
JSON.parse("{"); //!! SyntaxError: Expected property name or '}' in JSON at position 1 (line 1 column 2)
```

`//>` is a line of expected output, `//!` lists the diagnostics expected on
that line, and `//!!` is the uncaught exception the program ends with there. A
case with diagnostics never runs, so it can't expect output or an exception. `mise run test` checks zavascript against them, and `mise run oracle`
checks the expectations themselves against `tsc` and `node`, so a case can't
encode behavior that TypeScript doesn't have.
