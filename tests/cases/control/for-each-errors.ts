for (const x of 5) { //! TS2488
}
for (const k in 5) { //! TS2407
}
let n = 0;
for (n of ["a"]) { //! TS2322
}
for (const c of { a: 1 }) { //! TS2488
}
const o = { a: 1 };
for (o.a of [1]) { //! ZV9001
}
for (const [k] in o) { //! TS2491
}
for (const v of [1, 2]) {
  v = 3; //! TS2588
}
for (let v of [1, 2]) {
  v = "x"; //! TS2322
}
