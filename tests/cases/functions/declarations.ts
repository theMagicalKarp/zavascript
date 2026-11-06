// Declarations are hoisted: they can be called before they appear.
console.log(add(1, 2)); //> 3
function add(a: number, b: number) {
  return a + b;
}
function greet(name: string, greeting = "Hello") {
  return `${greeting}, ${name}!`;
}
console.log(greet("Ada")); //> Hello, Ada!
console.log(greet("Ada", "Hi")); //> Hi, Ada!
console.log(greet("Ada", undefined)); //> Hello, Ada!
function nothing() {}
console.log(nothing()); //> undefined
function early(x: number) {
  if (x > 0) {
    return "positive";
  }
  return;
}
console.log(early(1), early(-1)); //> positive undefined
function optional(a?: number) {
  return (a ?? 0) + 1;
}
console.log(optional(), optional(1)); //> 1 2
// A block's functions are scoped to it.
{
  function inner() {
    return "inner";
  }
  console.log(inner()); //> inner
}
