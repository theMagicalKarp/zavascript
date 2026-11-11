// An object literal is checked against the member of a union its discriminant picks.
type Shape = { kind: "circle"; radius: number } | { kind: "square"; side: number };
const a: Shape = { kind: "circle", radius: 1 };
const b: Shape = { kind: "square" }; //! TS2322
const c: Shape = { kind: "square", radius: 1 }; //! TS2353
const d: Shape = { kind: "triangle", side: 1 }; //! TS2322
const e: Shape = { kind: "circle", radius: "1" }; //! TS2322
const f: Shape | undefined = { kind: "circle", radius: 1, side: 2 }; //! TS2353
// Without a discriminant, a property just has to be in some member.
type Loose = { a: number } | { b: string };
const g: Loose = { a: 1, b: "x" };
const h: Loose = { c: 1 }; //! TS2353
