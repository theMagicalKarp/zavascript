// `let` and `const` declarations, with and without annotations.
let a = 1;
const b = "two";
let c: number = a + 1, d: string = b + c;
console.log(a, b, c, d); //> 1 two 2 two2
let e: boolean;
e = a < c;
console.log(e); //> true
let f: number;
f = 5;
f = f * 2;
console.log(f); //> 10
let g: undefined;
console.log(g); //> undefined
let h: any = "any";
h = 1;
console.log(h); //> 1
let i: unknown;
console.log(i); //> undefined
let j: void = undefined;
console.log(j); //> undefined
let k: null = null;
console.log(k); //> null
// Builtins can be shadowed.
{
  let undefined = 0, NaN = "not a number";
  console.log(undefined, NaN); //> 0 not a number
}
