// What tsc reports about index signatures.
const scores: { [name: string]: number } = { alice: "1" }; //! TS2322
scores.bob = "2"; //! TS2322
const readonlyScores: { readonly [name: string]: number } = {};
readonlyScores.a = 1; //! TS2542
interface Point {
  x: number;
}
const p: Point = { x: 1 };
const asIndex: { [k: string]: number } = p; //! TS2322
const bad: { [k: boolean]: number } = {}; //! TS1268
const r: Record<string, number> = { a: 1, b: "x" }; //! TS2322
