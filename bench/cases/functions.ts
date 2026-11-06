// Calls, recursion and closures: mostly measures the cost of a call.
function fib(n: number): number {
  return n < 2 ? n : fib(n - 1) + fib(n - 2);
}
console.log(fib(20));

function makeCounter() {
  let count = 0;
  return (step: number) => {
    count += step;
    return count;
  };
}
const counter = makeCounter();
let total = 0;
for (let i = 0; i < 20000; i++) {
  total = counter(i % 7);
}
console.log(total);

const compose = (f: (n: number) => number, g: (n: number) => number) => (n: number) => f(g(n));
const inc = (n: number) => n + 1;
const double = (n: number) => n * 2;
const both = compose(inc, double);
let acc = 0;
for (let i = 0; i < 20000; i++) {
  acc = (acc + both(i)) % 1000003;
}
console.log(acc);
