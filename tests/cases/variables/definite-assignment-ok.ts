// These are all definitely assigned before they're read.
let n = 2;
let a: number;
if (n > 1) {
  a = 1;
} else {
  a = 2;
}
console.log(a); //> 1
let b: number;
while (true) {
  b = 2;
  break;
}
console.log(b); //> 2
let c: number;
for (;;) {
  if (n) {
    c = 3;
    break;
  }
}
console.log(c); //> 3
let d: number;
do {
  d = 4;
} while (n < 0);
console.log(d); //> 4
let e: number;
switch (n) {
  case 1:
    e = 1;
    break;
  default:
    e = 5;
}
console.log(e); //> 5
let flag = n > 1;
let f: number;
switch (flag) {
  case true:
    f = 6;
    break;
  case false:
    f = 0;
    break;
}
console.log(f); //> 6
let g: number;
n ? (g = 7) : (g = 0);
console.log(g); //> 7
let h: number;
if (n && (h = 8)) {
  console.log(h); //> 8
}
let i: number;
if (true) {
  i = 9;
}
console.log(i); //> 9
let j: number;
(j = 10), console.log(j); //> 10
