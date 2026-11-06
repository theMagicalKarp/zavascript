function args() {
  return arguments; //! ZV9001
}
// Function declarations as the body of a statement are a syntax error in strict mode.
let flag = true;
if (flag) function g() {} //! ZV9001
// A function whose return type is itself.
function self() { //! ZV9001
  return self;
}
// A function expression's own rules for recursion.
const fe = function () { //! ZV9001
  return fe();
};
// Rest parameters typed by a context without one become tuples.
const takesOne: (a: number) => void = (...r) => {}; //! ZV9001
