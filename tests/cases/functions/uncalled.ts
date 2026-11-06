function f(cb: () => void, maybe?: () => void) {
  if (cb) { //! TS2774
  }
  if (maybe) {
  }
}
if (() => 1) { //! TS2872
}
const c = (() => 1, 2); //! TS2695
