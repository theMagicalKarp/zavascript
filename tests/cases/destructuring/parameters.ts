interface Point {
  x: number;
  y: number;
}
function length({ x, y }: Point): number {
  return Math_sqrt(x * x + y * y);
}
function Math_sqrt(n: number): number {
  let guess = n / 2;
  for (let i = 0; i < 20; i++) {
    guess = (guess + n / guess) / 2;
  }
  return guess;
}
console.log(length({ x: 3, y: 4 })); //> 5
const add = ([a, b]: [number, number]) => a + b;
console.log(add([1, 2])); //> 3
function withDefaults({ name = "anon", age = 0 } = {}) {
  return `${name} ${age}`;
}
console.log(withDefaults(), withDefaults({ name: "x" }), withDefaults({ age: 5 })); //> anon 0 x 0 anon 5
const points: Point[] = [{ x: 1, y: 2 }];
const sum = (f: (p: Point) => number) => f(points[0]);
console.log(sum(({ x, y }) => x + y)); //> 3
function rest(first: number, ...[second, third]: number[]) {
  return first + second + third;
}
console.log(rest(1, 2, 3)); //> 6
function nested({ inner: { value } }: { inner: { value: string } }) {
  return value;
}
console.log(nested({ inner: { value: "deep" } })); //> deep
console.log(length.length, withDefaults.length); //> 1 0
// Closures capture destructured parameters like any other.
function counter({ start }: { start: number }) {
  let n = start;
  return () => ++n;
}
const tick = counter({ start: 10 });
tick();
console.log(tick()); //> 12
