// Variables captured at several depths, through blocks, loops, switches and parameters.
function outer(a: number) {
  let b = a * 2;
  return (c: number) => {
    {
      let d = c + 1;
      const inner = () => a + b + c + d;
      b += 1;
      return inner;
    }
  };
}
const fn = outer(1)(10);
console.log(fn()); //> 25
// Parameters captured by their own defaults' closures.
function defaults(x: number, get = () => x) {
  x = 5;
  return get();
}
console.log(defaults(1)); //> 5
// A named function expression can call itself even when the variable changes.
let countdown = function down(n: number): number {
  return n === 0 ? 0 : down(n - 1) + 1;
};
const saved = countdown;
countdown = (n: number) => -1;
console.log(saved(3)); //> 3
// Closures created in a switch share its scope.
let fromSwitch = () => 0;
let which = 1;
switch (which) {
  case 1:
    let s = 1;
    fromSwitch = () => s;
    s = 2;
}
console.log(fromSwitch()); //> 2
// A `for` loop's update sees the copy for the next pass.
let getters = () => 0;
let log = "";
for (let i = 0, j = 10; i < 3; i++, j--) {
  const k = i;
  log += `${i}:${j} `;
  if (i === 1) {
    getters = () => i * 100 + j + k;
  }
}
console.log(log, getters()); //> 0:10 1:9 2:8  110
// Recursion with captured state.
function memo() {
  let calls = 0;
  function fib(n: number): number {
    calls++;
    return n < 2 ? n : fib(n - 1) + fib(n - 2);
  }
  return () => `${fib(15)} after ${calls} calls`;
}
console.log(memo()()); //> 610 after 1973 calls
