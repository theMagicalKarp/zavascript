function f(x: string | number | null | undefined) {
  if (x === null) {
    return "null";
  }
  if (x === undefined) {
    return "undefined";
  }
  if (x === "a" || x === 1) {
    return "a or 1: " + x;
  }
  return "other " + x;
}
console.log(f(null), f(undefined), f("a"), f(1), f(2)); //> null undefined a or 1: a a or 1: 1 other 2
// `==` and `!=` with `null` cover `undefined` too.
function g(x: number | null | undefined) {
  if (x != null) {
    return x + 1;
  }
  return x;
}
console.log(g(1), g(null), g(undefined)); //> 2 null undefined
// Comparing with another variable narrows both.
function h(a: "x" | "y", b: "y" | "z") {
  if (a === b) {
    const y: "y" = a;
    const also: "y" = b;
    return y + also;
  }
  return "different";
}
console.log(h("y", "y"), h("x", "y")); //> yy different
// A `string` compared with a literal is that literal.
function i(s: string) {
  if (s === "hello") {
    const h: "hello" = s;
    let copy = s;
    copy = "widened";
    return h + " " + copy;
  }
  return s;
}
console.log(i("hello"), i("bye")); //> hello widened bye
