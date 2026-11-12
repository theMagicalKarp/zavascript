// Arguments that need a contextual type are typed by what's inferred from the others.
function map<T, U>(items: T[], f: (item: T, index: number) => U): U[] {
  const out: U[] = [];
  for (let i = 0; i < items.length; i++) {
    out[i] = f(items[i], i);
  }
  return out;
}
const lengths = map([[1], [1, 2], [1, 2, 3]], (s) => s.length);
const doubled: number[] = map(lengths, (n) => n * 2);
console.log(lengths, doubled); //> [ 1, 2, 3 ] [ 2, 4, 6 ]

// The callback can come first.
function apply<T, R>(f: (x: T) => R, x: T): R {
  return f(x);
}
console.log(apply((n) => n + 1, 41)); //> 42

function filter<T>(items: T[], keep: (item: T) => boolean): T[] {
  const out: T[] = [];
  for (const item of items) {
    if (keep(item)) {
      out[out.length] = item;
    }
  }
  return out;
}
console.log(filter([1, 2, 3, 4], (n) => n % 2 === 0)); //> [ 2, 4 ]

function reduce<T, A>(items: T[], f: (acc: A, item: T) => A, init: A): A {
  let acc = init;
  for (const item of items) {
    acc = f(acc, item);
  }
  return acc;
}
console.log(reduce([1, 2, 3], (acc, n) => acc + n, 0)); //> 6
console.log(reduce(["a", "b"], (acc, s) => acc + s, "")); //> ab

// A generic function where a non-generic one is expected is instantiated for it.
function id<T>(x: T): T {
  return x;
}
const f: (x: number) => number = id;
console.log(map([1, 2], id), f(7)); //> [ 1, 2 ] 7

// Inferred from what the call is expected to return.
function empty<T>(): T[] {
  return [];
}
const none: string[] = empty();
console.log(none); //> []
