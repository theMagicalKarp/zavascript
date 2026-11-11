type Shape =
  | { kind: "circle"; radius: number }
  | { kind: "square"; side: number }
  | { kind: "rectangle"; width: number; height: number };
function area(s: Shape): number {
  if (s.kind === "circle") {
    return 3 * s.radius * s.radius;
  }
  if (s.kind === "square") {
    return s.side * s.side;
  }
  return s.width * s.height;
}
console.log(area({ kind: "circle", radius: 1 })); //> 3
console.log(area({ kind: "square", side: 2 })); //> 4
console.log(area({ kind: "rectangle", width: 2, height: 3 })); //> 6
// A boolean discriminant is narrowed by truthiness too.
type Result = { ok: true; value: number } | { ok: false; error: string };
function show(r: Result) {
  if (r.ok) {
    return "value " + r.value;
  }
  return "error " + r.error;
}
console.log(show({ ok: true, value: 1 }), show({ ok: false, error: "bad" })); //> value 1 error bad
// Through an optional chain, the object is narrowed to one that's there.
function maybe(r: Result | undefined) {
  if (r?.ok === false) {
    return r.error;
  }
  return r ? "fine" : "missing";
}
console.log(maybe({ ok: false, error: "e" }), maybe({ ok: true, value: 1 }), maybe(undefined)); //> e fine missing
// After every member is ruled out, nothing is left.
function exhausted(s: Shape) {
  if (s.kind === "circle") {
    return 1;
  } else if (s.kind === "square") {
    return 2;
  } else if (s.kind === "rectangle") {
    return 3;
  }
  const none: never = s;
  return none;
}
console.log(exhausted({ kind: "square", side: 1 })); //> 2
