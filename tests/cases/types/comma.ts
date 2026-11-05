let a = 1;
console.log((a, 2)); //! TS2695
console.log((1, 2)); //! TS2695
console.log(("s", typeof a, -a, !a, a ? 1 : 2, a + 1, 3)); //! TS2695 TS2695 TS2695 TS2695 TS2695 TS2695
console.log((a++, a = 2, void a, console.log(), 1));
