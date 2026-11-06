function f(a: number, b = 2, ...c: number[]) {
  return a;
}
const g = () => 1;
let h: () => void;
h = () => {};
console.log(f, g, h, () => 1, function named() {}); //> [Function: f] [Function: g] [Function: h] [Function (anonymous)] [Function: named]
console.log(f.name, f.length, g.name, (() => 1).name === ""); //> f 1 g true
console.log(typeof f, typeof g); //> function function
console.log(f === f, g === (() => 1)); //> true false
// Converting a function to a string gives its source, with types stripped the way node does.
const typed = (a: number, b?: string): number => a;
console.log("" + typed); //> (a        , b         )         => a
console.log(`${g}`); //> () => 1
