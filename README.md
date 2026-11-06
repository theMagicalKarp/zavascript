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
> zavascript is early. Today it runs `let` and `const` (with primitive, array
> and function type annotations), every operator including assignment, `if`,
> the loops, `switch`, labeled `break`/`continue`, functions (declarations,
> expressions and arrows, with closures, default, optional and rest
> parameters, and recursion), and `console.log`. The checker covers tsc's
> definite assignment, narrowing by assignment and truthiness, argument and
> return types, return type inference and contextual typing of arrow
> parameters. Objects, arrays and the rest are coming. Anything not supported
> yet is a compile error (`ZV9001`), never a silent misbehavior.

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
```

`//>` is a line of expected output and `//!` lists the diagnostics expected on
that line. `mise run test` checks zavascript against them, and `mise run oracle`
checks the expectations themselves against `tsc` and `node`, so a case can't
encode behavior that TypeScript doesn't have.
