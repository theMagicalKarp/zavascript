// Generic code: higher-order functions whose type arguments are inferred from callbacks, generic
// containers, and the utility types.
interface Box<T> {
  value: T;
}

function map<T, U>(items: T[], f: (item: T) => U): U[] {
  const out: U[] = [];
  for (let i = 0; i < items.length; i++) {
    out[i] = f(items[i]);
  }
  return out;
}

function filter<T>(items: T[], keep: (item: T) => boolean): T[] {
  const out: T[] = [];
  for (const item of items) {
    if (keep(item)) {
      out[out.length] = item;
    }
  }
  return out;
}

function reduce<T, A>(items: T[], f: (acc: A, item: T) => A, init: A): A {
  let acc = init;
  for (const item of items) {
    acc = f(acc, item);
  }
  return acc;
}

function get<T, K extends keyof T>(o: T, key: K): T[K] {
  return o[key];
}

interface Point {
  x: number;
  y: number;
}

function moved(p: Point, changes: Partial<Point>): Readonly<Point> {
  return { x: changes.x ?? p.x, y: changes.y ?? p.y };
}

const numbers: number[] = [];
for (let i = 0; i < 3000; i++) {
  numbers[i] = i;
}
const boxes = map(numbers, (n) => ({ value: n }));
const evens = filter(boxes, (b: Box<number>) => b.value % 2 === 0);
const total = reduce(evens, (acc, b) => acc + get(b, "value"), 0);
let p: Readonly<Point> = { x: 0, y: 0 };
for (let i = 0; i < 3000; i++) {
  p = moved(p, i % 2 === 0 ? { x: p.x + 1 } : { y: p.y + 2 });
}
console.log(total, p.x, p.y);
