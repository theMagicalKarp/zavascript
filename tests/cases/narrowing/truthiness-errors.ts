function f(x: string | null, y: number | undefined) {
  if (x) {
    const n: number = x; //! TS2322
  } else {
    const s: string = x; //! TS2322
  }
  if (!y) {
    y + 1; //! TS18048
  } else {
    const s: string = y; //! TS2322
  }
  x && x + 1;
  y || y + 1; //! TS18048
}
function g(u: unknown) {
  if (u) {
    u.a; //! TS2339
  }
}
