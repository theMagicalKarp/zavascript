// Using a variable before its declaration is fine inside a function that runs later.
const f = () => x + 1;
let x = 1;
console.log(f()); //> 2
function g() {
  return y;
}
const y = "y";
console.log(g()); //> y
