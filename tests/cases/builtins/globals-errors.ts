// The builtins are values with types, which tsc checks like any others.
Math.max("1"); //! TS2345
Math.foo(); //! TS2339
Math.f16round(1); //! TS2550
new Math(); //! TS2351
Map(); //! TS2348
new Map<string>(); //! TS2743
const m = new Map<string, number>();
m.set(1, 2); //! TS2345
m.get(1); //! TS2345
const v: number = m.get("a"); //! TS2322
new Set<number>(["a"]); //! TS2769
Number.isInteger(); //! TS2554
parseInt(5); //! TS2345
JSON.stringify(); //! TS2554
Object.keys(null); //! TS2769
Object.groupBy([1], (x) => x); //! TS2550 TS7006
Array.fromAsync([]); //! TS2550
console.log2("x"); //! TS2551
const big: string = Number.MAX_VALUE; //! TS2322
