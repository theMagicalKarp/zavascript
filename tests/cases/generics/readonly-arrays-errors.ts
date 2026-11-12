const xs: readonly number[] = [1, 2, 3];
xs[0] = 2; //! TS2542
const ys: number[] = xs; //! TS4104
function f(values: number[]) {}
f(xs); //! TS2345
