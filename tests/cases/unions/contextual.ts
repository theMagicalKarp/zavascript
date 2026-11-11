// A union gives an object literal's properties their context: literal types are kept, and
// functions get their parameters' types from the member the discriminant picks.
type Shape = { kind: "circle"; radius: number } | { kind: "square"; side: number };
const shapes: Shape[] = [
  { kind: "circle", radius: 1 },
  { kind: "square", side: 2 },
];
console.log(shapes); //> [ { kind: 'circle', radius: 1 }, { kind: 'square', side: 2 } ]
type Handler = { on: "number"; run: (x: number) => number } | { on: "string"; run: (x: string) => string };
const handler: Handler = { on: "number", run: (x) => x * 2 };
console.log(handler.on); //> number
const value: string | { a: 1 } = { a: 1 };
console.log(value); //> { a: 1 }
function area(s: Shape) {
  return s.kind === "circle" ? 3 * s.radius * s.radius : s.side * s.side;
}
console.log(area({ kind: "circle", radius: 2 }), area({ kind: "square", side: 3 })); //> 12 9
