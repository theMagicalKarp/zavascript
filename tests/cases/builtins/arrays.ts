// Array.prototype, and the types tsc gives what its methods return.
const xs = [3, 1, 2];
const doubled: number[] = xs.map((x) => x * 2);
console.log(doubled, xs.map((x, i) => `${i}:${x}`)); //> [ 6, 2, 4 ] [ '0:3', '1:1', '2:2' ]
console.log(xs.filter((x) => x > 1), xs.find((x) => x > 1), xs.find((x) => x > 5)); //> [ 3, 2 ] 3 undefined
console.log(xs.findIndex((x) => x === 2), xs.some((x) => x > 2), xs.every((x) => x > 0)); //> 2 true true
console.log(xs.indexOf(2), xs.indexOf(9), xs.lastIndexOf(3), xs.includes(1), [NaN].includes(NaN), [NaN].indexOf(NaN)); //> 2 -1 0 true true -1
console.log(xs.slice(1), xs.slice(-2, -1), xs.slice(), xs.at(0), xs.at(-1), xs.at(3)); //> [ 1, 2 ] [ 1 ] [ 3, 1, 2 ] 3 2 undefined
console.log(xs.concat([4, 5], 6), xs.join(), xs.join(" - "), [1, [2, [3]]].join(";"), String([null, undefined, 1])); //> [ 3, 1, 2, 4, 5, 6 ] 3,1,2 3 - 1 - 2 1;2,3 ,,1
const total: number = xs.reduce((sum, x) => sum + x, 0);
const longest: string = ["a", "bbb", "cc"].reduce((a, b) => (a.length >= b.length ? a : b));
const lengths: number = ["a", "bbb"].reduce((sum, s) => sum + s.length, 0);
console.log(total, longest, lengths, xs.reduceRight((acc, x) => acc + x, "")); //> 6 bbb 4 213
// Mutators.
const ys = [5, 1, 10, 2];
console.log(ys.push(7, 8), ys, ys.pop(), ys.shift(), ys.unshift(0), ys); //> 6 [ 0, 1, 10, 2, 7 ] 8 5 5 [ 0, 1, 10, 2, 7 ]
console.log(ys.splice(1, 2), ys, ys.splice(1, 0, 9, 9), ys, ys.splice(-1), ys); //> [ 1, 10 ] [ 0, 9, 9, 2 ] [] [ 0, 9, 9, 2 ] [ 7 ] [ 0, 9, 9, 2 ]
console.log(ys.reverse(), ys.fill(4, 1, 3), [1, 2, 3].fill(0)); //> [ 2, 4, 4, 0 ] [ 2, 4, 4, 0 ] [ 0, 0, 0 ]
// `sort` compares strings unless given a comparator, and keeps equal elements in order.
console.log([10, 9, 1, 100].sort(), [10, 9, 1, 100].sort((a, b) => a - b), ["b", undefined, "a"].sort()); //> [ 1, 10, 100, 9 ] [ 1, 9, 10, 100 ] [ 'a', 'b', undefined ]
const people = [{ name: "a", age: 30 }, { name: "b", age: 20 }, { name: "c", age: 30 }];
console.log(people.sort((p, q) => p.age - q.age).map((p) => p.name).join("")); //> bac
// Flattening.
const nested = [[1], [2, [3, [4]]]];
const flat: (number | (number | number[])[])[] = nested.flat();
console.log(flat, nested.flat(2), [["a b"], ["c"]].flat().flatMap((s) => s.split(" "))); //> [ 1, 2, [ 3, [ 4 ] ] ] [ 1, 2, 3, [ 4 ] ] [ 'a', 'b', 'c' ]
const pairs = ["x", "y"].flatMap((s, i) => [s, i]);
console.log(pairs); //> [ 'x', 0, 'y', 1 ]
// Iterators.
console.log([...["a", "b"].entries()], [...["a", "b"].keys()], [...["a", "b"].values()]); //> [ [ 0, 'a' ], [ 1, 'b' ] ] [ 0, 1 ] [ 'a', 'b' ]
for (const [i, letter] of ["a", "b"].entries()) {
  console.log(i, letter);
//> 0 a
//> 1 b
}
// The callback sees the index and the array.
[7, 8].forEach((x, i, all) => console.log(x, i, all.length));
//> 7 0 2
//> 8 1 2
// Array, the constructor.
console.log(Array.isArray(xs), Array.isArray("xs"), Array.of(1, 2), Array.from("abc"), Array.from(new Set([1, 1, 2]))); //> true false [ 1, 2 ] [ 'a', 'b', 'c' ] [ 1, 2 ]
console.log(Array.from({ length: 3 }, (_, i) => i * i), Array.from([1, 2], (x) => x + 1)); //> [ 0, 1, 4 ] [ 2, 3 ]
const readonlyXs: readonly number[] = [1, 2, 3];
console.log(readonlyXs.map((x) => x + 1), readonlyXs.indexOf(2), readonlyXs.length); //> [ 2, 3, 4 ] 1 3
const cyclic: any[] = [1];
cyclic.push(cyclic);
const outer: any[] = [1, [2]];
outer[1].push(outer);
console.log(String(cyclic), `${cyclic}`, cyclic.join("-"), outer.join("-"), String(outer)); //> 1, 1, 1- 1-2, 1,2,
let deep: any[] = [];
for (let i = 0; i < 1000; i++) {
  deep = [deep, i];
}
console.log(String(deep).length, deep.join("-").slice(0, 12)); //> 3890 ,0,1,2,3,4,5
