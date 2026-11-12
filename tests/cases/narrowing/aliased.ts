// A condition stored in a `const` narrows where it's tested, as if it were written there.
function describe(x: string | number) {
  const isString = typeof x === "string";
  if (isString) {
    return "string " + x;
  }
  return "number " + (x + 1);
}
console.log(describe("a"), describe(1)); //> string a number 2
type Result = { ok: true; value: number } | { ok: false; error: string };
function show(r: Result) {
  const ok = r.ok;
  return ok ? "value " + r.value : "error " + r.error;
}
console.log(show({ ok: true, value: 1 }), show({ ok: false, error: "e" })); //> value 1 error e
// They combine, and can refer to each other.
function both(x: number | null, y: string | undefined) {
  const hasX = x !== null;
  const ready = hasX && y !== undefined;
  if (ready) {
    return y + x;
  }
  return "not ready";
}
console.log(both(1, "y"), both(null, "y")); //> y1 not ready
// Its initializer still reads the names it was declared with, even where they're shadowed.
function shadowed(x: string | number) {
  const isString = typeof x === "string";
  {
    const x = 1;
    if (isString) {
      console.log("string", x); //> string 1
    }
  }
  return isString;
}
console.log(shadowed("abc")); //> true
