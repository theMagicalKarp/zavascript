const xs: readonly number[] = [1, 2, 3];
const ys: ReadonlyArray<string> = ["a"];
console.log(xs[0], xs.length, ys); //> 1 3 [ 'a' ]
for (const x of xs) {
  console.log(x); //> 1
  break;
}
// A mutable array can be used as a readonly one.
const mutable: number[] = [4];
const view: readonly number[] = mutable;
console.log([...view, ...xs]); //> [ 4, 1, 2, 3 ]
function sum(values: readonly number[]): number {
  let total = 0;
  for (const v of values) {
    total += v;
  }
  return total;
}
console.log(sum(mutable), sum(xs)); //> 4 6
