function f(x: "a" | "b" | null) {
  if (x === "a") {
    const b: "b" = x; //! TS2322
  } else {
    const a: "a" = x; //! TS2322
  }
  if (x !== null) {
    const n: null = x; //! TS2322
  }
  if (x == undefined) {
    const s: string = x; //! TS2322
  }
  if (x === "a") {
    console.log(x === "b"); //! TS2367
  }
}
function unknownAgainst(x: unknown, y: any, z: string | number, w: string) {
  if (x === y) {
    const n: number = x; //! TS2322
  }
  if (x === z) {
    const n: number = x; //! TS2322
  }
  if (x === w) {
    const s: string = x;
  }
}
