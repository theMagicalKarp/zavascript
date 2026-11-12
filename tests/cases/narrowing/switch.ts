type Shape = { kind: "circle"; radius: number } | { kind: "square"; side: number };
// Each case narrows to its member, and a switch with a case for every one of them is
// exhaustive, so the function doesn't need a return after it.
function area(s: Shape): number {
  switch (s.kind) {
    case "circle":
      return 3 * s.radius * s.radius;
    case "square":
      return s.side * s.side;
  }
}
console.log(area({ kind: "circle", radius: 2 }), area({ kind: "square", side: 3 })); //> 12 9
function assertNever(x: never): never {
  throw x;
}
function name(s: Shape) {
  switch (s.kind) {
    case "circle":
      return "circle";
    case "square":
      return "square";
    default:
      return assertNever(s);
  }
}
console.log(name({ kind: "square", side: 1 })); //> square
// Cases that fall through narrow to either.
function size(x: "s" | "m" | "l" | "xl") {
  switch (x) {
    case "s":
    case "m": {
      const small: "s" | "m" = x;
      return small;
    }
    default: {
      const big: "l" | "xl" = x;
      return big;
    }
  }
}
console.log(size("m"), size("xl")); //> m xl
// Without a `default`, what no case matched carries on after the switch.
function rest(x: "a" | "b" | "c") {
  switch (x) {
    case "a":
      return 1;
    case "b":
      return 2;
  }
  const c: "c" = x;
  return c;
}
console.log(rest("a"), rest("c")); //> 1 c
function kind(x: string | number | boolean) {
  switch (typeof x) {
    case "string":
      return "string of " + x;
    case "number":
      return "number " + (x + 1);
    default: {
      const b: boolean = x;
      return b;
    }
  }
}
console.log(kind("s"), kind(1), kind(true)); //> string of s number 2 true
function typeofExhaustive(x: string | number): string {
  switch (typeof x) {
    case "string":
      return "s";
    case "number":
      return "n";
  }
}
console.log(typeofExhaustive(1)); //> n
