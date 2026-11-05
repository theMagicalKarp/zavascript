let out = "";
for (let i = 0; i < 10; i++) {
  if (i % 2 === 1) continue;
  if (i > 6) break;
  out += i;
}
console.log(out); //> 0246
let n = 0;
while (true) {
  n++;
  if (n < 5) continue;
  break;
}
console.log(n); //> 5
let d = 0;
do {
  d++;
  if (d === 2) continue;
  if (d === 4) break;
} while (d < 10);
console.log(d); //> 4
outer: for (let a = 0; a < 3; a++) {
  for (let b = 0; b < 3; b++) {
    if (b > a) continue outer;
    if (a === 2) break outer;
    console.log(a, b);
  }
}
//> 0 0
//> 1 0
//> 1 1
block: {
  console.log("in block"); //> in block
  if (n) break block;
  console.log("never");
}
a: b: while (true) {
  while (true) {
    break a;
  }
}
console.log("done"); //> done
