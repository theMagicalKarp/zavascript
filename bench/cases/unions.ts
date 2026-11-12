// Union-heavy code: discriminated unions narrowed by `switch`, `typeof` and `in`, optional
// chaining, and `??`.
type Shape =
  | { kind: "circle"; radius: number }
  | { kind: "square"; side: number }
  | { kind: "rectangle"; width: number; height: number };

function area(s: Shape): number {
  switch (s.kind) {
    case "circle":
      return 3 * s.radius * s.radius;
    case "square":
      return s.side * s.side;
    case "rectangle":
      return s.width * s.height;
  }
}

const shapes: Shape[] = [];
for (let i = 0; i < 3000; i++) {
  const n = i % 3;
  if (n === 0) {
    shapes[i] = { kind: "circle", radius: i % 7 };
  } else if (n === 1) {
    shapes[i] = { kind: "square", side: i % 11 };
  } else {
    shapes[i] = { kind: "rectangle", width: i % 5, height: i % 13 };
  }
}
let total = 0;
for (let round = 0; round < 10; round++) {
  for (const s of shapes) {
    total += area(s);
  }
}
console.log(total);

function weight(x: string | number | boolean | null | undefined): number {
  if (x === null || x === undefined) {
    return 0;
  }
  if (typeof x === "string") {
    return 1;
  }
  if (typeof x === "number") {
    return x;
  }
  return x ? 2 : 3;
}
const values: (string | number | boolean | null | undefined)[] = ["a", 1, true, null, undefined, false, 7];
let weights = 0;
for (let i = 0; i < 20000; i++) {
  weights += weight(values[i % 7]);
}
console.log(weights);

interface Node {
  value: number;
  next?: Node;
}
let head: Node | undefined;
for (let i = 0; i < 200; i++) {
  head = { value: i, next: head };
}
let walked = 0;
for (let round = 0; round < 100; round++) {
  let node = head;
  while (node) {
    walked += node.next?.value ?? 0;
    node = node.next;
  }
}
console.log(walked);
