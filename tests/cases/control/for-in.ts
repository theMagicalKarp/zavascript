const scores = { b: 2, a: 1, 10: 3, 2: 4 };
for (const k in scores) {
  console.log(k, typeof k);
}
//> 2 string
//> 10 string
//> b string
//> a string
for (const i in ["x", "y"]) console.log(i); //> 0
//> 1
// Properties deleted before they're reached aren't visited.
const o: { a: number; b?: number; c?: number } = { a: 1, b: 2, c: 3 };
for (const k in o) {
  console.log(k);
  delete o.c;
}
//> a
//> b
let key = "";
for (key in { only: 1 }) {
}
console.log(key); //> only
const visited: string[] = [];
for (const k in { x: 1, y: 2, z: 3 }) {
  if (k === "y") continue;
  visited[visited.length] = k;
}
console.log(visited); //> [ 'x', 'z' ]
