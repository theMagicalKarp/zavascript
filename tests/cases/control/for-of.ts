let total = 0;
for (const n of [1, 2, 3]) total += n;
console.log(total); //> 6
const pairs: [string, number][] = [
  ["a", 1],
  ["b", 2],
];
for (const [name, value] of pairs) {
  console.log(name, value);
}
//> a 1
//> b 2
// Each pass gets its own binding.
const fns: (() => number)[] = [];
for (const n of [1, 2, 3]) {
  fns[fns.length] = () => n * 10;
}
console.log(fns[0](), fns[1](), fns[2]()); //> 10 20 30
// An existing variable can be the target.
let last = 0;
for (last of [4, 5, 6]) {
}
console.log(last); //> 6
// Elements added while looping are visited.
const grow = [1];
for (const g of grow) {
  if (g < 3) {
    grow[grow.length] = g + 1;
  }
}
console.log(grow); //> [ 1, 2, 3 ]
outer: for (const a of [1, 2, 3]) {
  for (const b of [1, 2, 3]) {
    if (b === 2) continue outer;
    if (a === 3) break outer;
    console.log(a, b);
  }
}
//> 1 1
//> 2 1
