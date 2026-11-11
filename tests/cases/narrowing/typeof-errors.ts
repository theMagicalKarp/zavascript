function f(x: string | number | null) {
  if (typeof x === "string") {
    const n: number = x; //! TS2322
  } else {
    const s: string = x; //! TS2322
  }
  if (typeof x === "object") {
    const n: number = x; //! TS2322
  }
  if (typeof x === "function") {
    const n: never = x;
  }
  if (typeof x === "strnig") { //! TS2367
  }
}
function g(u: unknown) {
  if (typeof u !== "string") {
    u.length; //! TS18046
  }
}
