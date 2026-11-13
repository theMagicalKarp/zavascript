// Variables whose type would evolve with each assignment.
let a; //! ZV9001
let b = null; //! ZV9001
let c = undefined; //! ZV9001
// Builtins aren't writable yet.
NaN = 1; //! ZV9001
// Library types we don't have yet.
let d: Date; //! ZV9001
// A declaration in one `case` read from another throws a ReferenceError, which isn't
// implemented yet. (tsc only catches this when the type can't hold `undefined`.)
switch (1 + 1) {
  case 1:
    let e: any = 1;
    break;
  case 2:
    console.log(e); //! ZV9001
    e = 2; //! ZV9001
}
