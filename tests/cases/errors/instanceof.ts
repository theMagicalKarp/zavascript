// `instanceof` with the builtin constructors, and how it narrows.

console.log([] instanceof Array, [] instanceof Object, {} instanceof Array); //> true true false
console.log(new Map() instanceof Map, new Set() instanceof Map, new Set() instanceof Set); //> true false true
console.log(new Map() instanceof Object, (() => 1) instanceof Object); //> true true

function describe(x: Error | string[] | Map<string, number> | string): string {
  if (x instanceof Error) {
    return "error " + x.message;
  }
  if (x instanceof Array) {
    return "array of " + x.length;
  }
  if (x instanceof Map) {
    return "map of " + x.size;
  }
  return "string " + x.toUpperCase();
}
console.log(describe(new Error("e"))); //> error e
console.log(describe(["a"])); //> array of 1
console.log(describe(new Map([["a", 1]]))); //> map of 1
console.log(describe("s")); //> string S

// Errors are told apart by what they're declared to extend, not by their shape.
function kind(e: TypeError | RangeError): string {
  if (e instanceof TypeError) {
    const t: TypeError = e;
    return "type " + t.message;
  }
  const r: RangeError = e;
  return "range " + r.message;
}
console.log(kind(new TypeError("a")), kind(new RangeError("b"))); //> type a range b

function fromUnknown(x: unknown): string {
  if (x instanceof Error) {
    return x.message;
  }
  if (x instanceof Array) {
    return "array " + x.length;
  }
  return "other";
}
console.log(fromUnknown(new SyntaxError("s")), fromUnknown([1, 2]), fromUnknown(1)); //> s array 2 other

const maybe: Error | undefined = Math.random() < 2 ? new Error("m") : undefined;
console.log(maybe instanceof Error && maybe.message); //> m
const value: any = new Error("any");
console.log(value instanceof Error); //> true

// Methods and builtin functions that aren't constructors have no `prototype`.
const withMethod = { m() {} };
const notConstructors: any[] = [withMethod.m, console.log, () => 1];
for (const f of notConstructors) {
  try {
    console.log({} instanceof f);
  } catch (x) {
    console.log(String(x)); //> TypeError: Function has non-object prototype 'undefined' in instanceof check
    //> TypeError: Function has non-object prototype 'undefined' in instanceof check
    //> TypeError: Function has non-object prototype 'undefined' in instanceof check
  }
}
console.log({} instanceof function () {}); //> false
