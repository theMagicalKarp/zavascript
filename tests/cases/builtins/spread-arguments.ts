// Spreading an array or iterable into a call's arguments.
const xs = [3, 1, 2];
console.log(Math.max(...xs), Math.min(...xs, 0), Math.max(...new Set([4, 5]))); //> 3 0 5
function sum(...ns: number[]): number {
  return ns.reduce((a, b) => a + b, 0);
}
console.log(sum(...xs), sum(1, ...xs, ...[10]), sum(...[])); //> 6 17 0
function pair(a: number, b: string) {
  return `${a}${b}`;
}
const args: [number, string] = [1, "x"];
console.log(pair(...args)); //> 1x
const words = ["a", "b"];
console.log(...words, ..."cd"); //> a b c d
console.log([..."hi"].concat(...[["!"]])); //> [ 'h', 'i', '!' ]
