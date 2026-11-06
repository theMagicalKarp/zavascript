function apply(f: (n: number) => number, value: number) {
  return f(value);
}
console.log(apply((x) => x * 2, 21)); //> 42
console.log(apply(function (x) { return x + 1; }, 1)); //> 2
const twice: (s: string) => string = (s) => s + s;
console.log(twice("ab")); //> abab
let handler: (n: number) => void;
handler = (n) => console.log(n + 1);
handler(1); //> 2
const fewer: (a: number, b: number) => number = (a) => a;
console.log(fewer(5, 6)); //> 5
const pick = true ? (n: number) => n : (n: number) => -n;
console.log(pick(3)); //> 3
