const pair: [string, number] = ["a", 1];
console.log(pair, pair[0], pair[1], pair.length); //> [ 'a', 1 ] a 1 2
pair[1] = 2;
pair[0] += "b";
console.log(pair); //> [ 'ab', 2 ]
function swap(p: [number, string]): [string, number] {
  return [p[1], p[0]];
}
console.log(swap([1, "x"])); //> [ 'x', 1 ]
const nested: [[number, number], string][] = [[[1, 2], "a"]];
console.log(nested); //> [ [ [ 1, 2 ], 'a' ] ]
const numbers: [number, number] = [1, 2];
const asArray: number[] = numbers;
console.log(asArray); //> [ 1, 2 ]
let n: number = 0;
const k = 0;
n = [5, 6][k];
console.log(n); //> 5
