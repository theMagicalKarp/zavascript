function fact(n: number) { //! TS7023
  return n <= 1 ? 1 : n * fact(n - 1);
}
function even(n: number) { //! TS7023
  return n === 0 ? true : odd(n - 1);
}
function odd(n: number) { //! TS7023
  return n === 0 ? false : even(n - 1);
}
const loop = () => loop(); //! TS7023
