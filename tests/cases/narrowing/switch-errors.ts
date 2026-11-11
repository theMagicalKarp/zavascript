type Shape = { kind: "circle"; radius: number } | { kind: "square"; side: number };
function area(s: Shape): number { //! TS2366
  switch (s.kind) {
    case "circle":
      return 1;
  }
}
function f(s: Shape) {
  switch (s.kind) {
    case "circle":
      s.side; //! TS2339
      break;
    case "square":
      s.radius; //! TS2339
      break;
    default:
      const n: never = s;
  }
}
function g(s: Shape) {
  switch (s.kind) {
    case "circle":
      break;
    default:
      const n: never = s; //! TS2322
  }
}
function h(x: string | number) {
  switch (typeof x) {
    case "string":
      const n: number = x; //! TS2322
  }
}
