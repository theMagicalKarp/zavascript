function id<T>(x: T): T {
  return x;
}
console.log(id(1), id("a"), id(true)); //> 1 a true
// A literal stays a literal when the type parameter is the whole return type.
const one = id(1);
const two: 1 = one;
let widened = id(1);
widened = 5;
console.log(two, widened); //> 1 5

// Explicit type arguments.
console.log(id<string>("x"), id<number | string>(2)); //> x 2

// Several type parameters, inferred from several arguments.
function pair<A, B>(a: A, b: B): [A, B] {
  return [a, b];
}
const p = pair(1, "b");
const first: number = p[0];
const second: string = p[1];
console.log(first, second); //> 1 b

// Literals of one primitive make a union; widened when not returned directly.
function both<T>(a: T, b: T): T[] {
  return [a, b];
}
const xs: number[] = both(1, 2);
console.log(xs); //> [ 1, 2 ]

// Generic arrows and function expressions.
const first2 = <T>(items: T[]): T | undefined => items[0];
const last = function <T>(items: T[]): T | undefined {
  return items[items.length - 1];
};
console.log(first2([3, 4]), last(["c", "d"])); //> 3 d

// Recursion.
function repeat<T>(x: T, n: number): T[] {
  return n <= 0 ? [] : [x, ...repeat(x, n - 1)];
}
console.log(repeat("z", 3)); //> [ 'z', 'z', 'z' ]

// A type parameter can be used for locals.
function swap<A, B>(t: [A, B]): [B, A] {
  const a: A = t[0];
  const b: B = t[1];
  return [b, a];
}
console.log(swap([1, "x"])); //> [ 'x', 1 ]

// A rest parameter can be a readonly array.
function total(...xs: readonly number[]): number {
  let sum = 0;
  for (const x of xs) {
    sum += x;
  }
  return sum;
}
console.log(total(1, 2, 3)); //> 6

// Calling itself adds nothing to the return type it's inferred.
function countdown<T>(x: T, n: number) {
  if (n > 0) {
    return countdown(x, n - 1);
  }
  return x;
}
const counted: number = countdown(7, 3);
console.log(counted); //> 7

// A generic call in an argument doesn't take the outer call's type parameters as its own.
function make<U>(): U {
  return [] as any;
}
function wrapOne<V>(v: V): V[] {
  return [v];
}
const made: number[][] = wrapOne(make());
console.log(made); //> [ [] ]

// A generic function in an object or array is instantiated for the function type expected there.
const ops: { f: (x: number) => number } = { f: id };
const fns: ((x: string) => string)[] = [id];
const tup: [(x: boolean) => boolean, number] = [id, 1];
console.log(ops.f(1), fns[0]("s"), tup[0](true)); //> 1 s true
