function describe(x: string | number | boolean | undefined | { a: number } | (() => number)): string {
  if (typeof x === "string") {
    return "string " + x;
  }
  if (typeof x === "number") {
    return "number " + (x * 2);
  }
  if (typeof x === "boolean") {
    return x ? "yes" : "no";
  }
  if (typeof x === "undefined") {
    return "nothing";
  }
  if (typeof x === "function") {
    return "function " + x();
  }
  return "object " + x.a;
}
console.log(describe("a")); //> string a
console.log(describe(2)); //> number 4
console.log(describe(false)); //> no
console.log(describe(undefined)); //> nothing
console.log(describe(() => 7)); //> function 7
console.log(describe({ a: 1 })); //> object 1
// The other way round, and with `!==`.
function length(x: string | number[] | null) {
  if ("string" === typeof x) {
    return 0;
  }
  if (typeof x !== "object") {
    const never: never = x;
    return never;
  }
  return x === null ? -1 : x.length;
}
console.log(length("abc"), length([1, 2]), length(null)); //> 0 2 -1
// `typeof` narrows `any` and `unknown` to the primitive it names.
function fromUnknown(u: unknown) {
  if (typeof u === "number") {
    return u + 1;
  }
  if (typeof u === "boolean") {
    return !u;
  }
  return u;
}
console.log(fromUnknown(1), fromUnknown(true), fromUnknown("s")); //> 2 false s
function fromAny(a: any) {
  if (typeof a === "string") {
    const s: string = a;
    return s;
  }
  return "other";
}
console.log(fromAny("x"), fromAny(1)); //> x other
