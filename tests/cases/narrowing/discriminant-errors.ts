type Shape = { kind: "circle"; radius: number } | { kind: "square"; side: number };
function f(s: Shape) {
  if (s.kind === "circle") {
    s.side; //! TS2339
  } else {
    s.radius; //! TS2339
  }
  if (s.kind !== "square") {
    const c: { kind: "circle"; radius: number } = s;
  } else {
    const n: never = s; //! TS2322
  }
  s.radius; //! TS2339
}
function g(s: Shape) {
  if (s.kind === "circle") {
    return;
  }
  const n: never = s; //! TS2322
}
