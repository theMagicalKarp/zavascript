interface Point {
  x: number;
  y: number;
}
interface Named {
  name: string;
  label?: string;
}
type Pair = { left: Point; right: Point };
const ok: Point = { x: 1, y: 2 };
const missing: Point = { x: 1 }; //! TS2741
const many: Pair = {}; //! TS2739
const extra: Point = { x: 1, y: 2, z: 3 }; //! TS2353
const wrong: Point = { x: 1, y: "2" }; //! TS2322
const deep: Pair = {
  left: { x: 1, y: 2 },
  right: { x: 1, y: 2, w: 0 }, //! TS2353
};
const deeper: Pair = {
  left: { x: 1 }, //! TS2741
  right: ok,
};
const fromVariable = { x: 1, y: 2, z: 3 };
const noExcessCheck: Point = fromVariable;
const named: Named = { name: "n" };
const notNamed: Named = ok; //! TS2741
function takesPoint(p: Point): number {
  return p.x;
}
takesPoint({ x: 1 }); //! TS2345
takesPoint({ x: 1, y: 2, z: 3 }); //! TS2353
takesPoint({ x: 1, y: true }); //! TS2322
const optionalToRequired: { name: string; label: string } = named; //! TS2322
const asEmpty: {} = ok;
const structural: { x: number } = ok;
function point(): Point {
  return { x: 1, y: 2, extra: true }; //! TS2353
}
let reassigned: Point = ok;
reassigned = { x: 1 }; //! TS2741
