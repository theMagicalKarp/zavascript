const square = (x: number) => x * x;
console.log(square(7)); //> 49
const block = (a: number, b: number): number => {
  const sum = a + b;
  return sum * 2;
};
console.log(block(1, 2)); //> 6
const named = function fib(n: number): number {
  return n < 2 ? n : fib(n - 1) + fib(n - 2);
};
console.log(named(10)); //> 55
const curry = (a: number) => (b: number) => a + b;
console.log(curry(1)(2)); //> 3
console.log(((x: string) => x + "!")("hi")); //> hi!
const noArgs = () => "none";
console.log(noArgs()); //> none
