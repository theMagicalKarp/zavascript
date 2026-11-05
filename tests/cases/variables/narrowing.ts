// An assignment narrows a variable whose type is a union, like `boolean`.
let b = true;
console.log(b === false); //! TS2367
let c: boolean = false;
c = true;
console.log(c === false); //! TS2367
let d = true;
d = !d;
console.log(d === true); //! TS2367
const e = 1;
console.log(e === 2); //! TS2367
let t = typeof e;
t = "number";
console.log(t === "string"); //! TS2367
let u = e ? "a" : 1;
u = "b";
console.log(u * 2); //! TS2362
let f = false;
f ||= true;
console.log(f === false); //! TS2367
// Testing a variable narrows it in each branch.
let g = 1 < 2;
if (g) {
  console.log(g === false); //! TS2367
} else {
  console.log(g === true); //! TS2367
}
let h = true;
while (h) {
  h = false;
}
console.log(h === true); //! TS2367
