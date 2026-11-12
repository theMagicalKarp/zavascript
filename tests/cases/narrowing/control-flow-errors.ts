function inferred(message: string) {
  throw message;
}
function f(x: number | null): number {
  if (x === null) {
    // Only a function whose type says `never` ends the code path.
    inferred("null");
  }
  return x; //! TS2322
}
function g(x: number | null) {
  if (x === null) {
    throw "null";
  }
  const n: null = x; //! TS2322
}
function h(): never { //! TS2534
  console.log("returns");
}
function k(): never {
  throw "always";
}
const fe = function (): never { //! TS2534
};
