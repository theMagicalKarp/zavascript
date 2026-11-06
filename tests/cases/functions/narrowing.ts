function f(a?: number) {
  if (a) {
    // Narrowing where a closure is created carries into it when nothing assigns `a` later.
    const g = () => a + 1;
    function h() {
      return a + 1; //! TS18048
    }
  }
  const k = () => a + 1; //! TS18048
}
function assigned(a?: number) {
  a = 1;
  const k = () => a + 1;
}
function reassigned(a?: number) {
  a = 1;
  const k = () => a + 1; //! TS18048
  a = undefined;
}
// Inside a closure, an enclosing function's variable narrows like any other.
function inside(a?: number) {
  return () => {
    if (a) {
      return a + 1;
    }
    return 0;
  };
}
let never: number;
const n = () => never; //! TS2454
let later: number;
const l = () => later;
later = 1;
