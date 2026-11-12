// `unknown` has to be narrowed before it can be used.
function show(u: unknown) {
  if (typeof u === "string") {
    return "string " + u;
  }
  if (typeof u === "number") {
    return "number " + u * 2;
  }
  if (u === null) {
    return "null";
  }
  if (u === undefined) {
    return "undefined";
  }
  if (u === true) {
    const t: true = u;
    return t;
  }
  return "other";
}
console.log(show("s"), show(2), show(null), show(undefined), show(true), show(false)); //> string s number 4 null undefined true other
function present(u: unknown) {
  if (u != null) {
    const value: {} = u;
    return value;
  }
  return "absent";
}
console.log(present(0), present(null)); //> 0 absent
