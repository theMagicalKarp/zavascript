// A variable can't be read until it's been assigned on every path that gets there.
let m = 1;
let a: number;
console.log(a); //! TS2454
let b: number;
b += 1; //! TS2454
let c: number;
c++; //! TS2454
let d: string;
if (m) {
  d = "x";
}
console.log(d); //! TS2454
let e: number;
while (m) {
  e = 1;
}
console.log(e); //! TS2454
let f: number;
switch (m) {
  case 1:
    f = 1;
    break;
}
console.log(f); //! TS2454
let g: number;
lbl: {
  if (m) {
    break lbl;
  }
  g = 1;
}
console.log(g); //! TS2454
let h: number;
m && (h = 1);
console.log(h); //! TS2454
switch (m) {
  case 1:
    let i = 1;
    break;
  case 2:
    console.log(i); //! TS2454
}
let j: boolean;
console.log(typeof j); //! TS2454
