const xs = [1, 2, 3];
console.log(xs, xs.length, xs[0], xs[5]); //> [ 1, 2, 3 ] 3 1 undefined
const more = [0, ...xs, 4];
console.log(more); //> [ 0, 1, 2, 3, 4 ]
const mixed = [1, "a", true, null, undefined];
console.log(mixed); //> [ 1, 'a', true, null, undefined ]
const grid = [
  [1, 2],
  [3, 4],
];
console.log(grid, grid[1][0]); //> [ [ 1, 2 ], [ 3, 4 ] ] 3
xs[1] = 20;
xs[xs.length] = 4;
xs[0] += 10;
xs[2]++;
console.log(xs); //> [ 11, 20, 4, 4 ]
const i = 1;
console.log(xs[i], xs["0"], xs[i + 1]); //> 20 11 4
const empty: number[] = [];
empty[0] = 1;
console.log(empty, [], [[]]); //> [ 1 ] [] [ [] ]
console.log(`${[1, [2, 3]]}`, [1, 2] + "", +[], +[7]); //> 1,2,3 1,2 0 7
const aliased = xs;
aliased[0] = 0;
console.log(xs[0]); //> 0
const long = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27];
console.log(long); //> [
//>    1,  2,  3,  4,  5,  6,  7,  8,
//>    9, 10, 11, 12, 13, 14, 15, 16,
//>   17, 18, 19, 20, 21, 22, 23, 24,
//>   25, 26, 27
//> ]
const words = ["alpha", "beta", "gamma", "delta", "epsilon", "zeta", "eta", "theta"];
console.log({ words }); //> {
//>   words: [
//>     'alpha',   'beta',
//>     'gamma',   'delta',
//>     'epsilon', 'zeta',
//>     'eta',     'theta'
//>   ]
//> }
