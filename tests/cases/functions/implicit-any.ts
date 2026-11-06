function f(a) {} //! TS7006
function g(...r) {} //! TS7019
const h = (x, y = 1) => x; //! TS7006
let t: (x) => void; //! TS7006
// A parameter with a default value has its value's type.
function d(n = 1) {
  const s: string = n; //! TS2322
}
