function f(x: unknown) {
  if (typeof x === "object") { //! ZV9001
  }
}
function g(x: { a: number }) {
  if ("b" in x) { //! ZV9001
  }
}
const h = [1, 2] as const; //! ZV9001
function k(f: (() => void) | ((x: number) => void)) {
  f(1); //! ZV9001
}
function l(x: string | number) {
  x.toString; //! ZV9001
}
const m = `m${1}` as const; //! ZV9001
