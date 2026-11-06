function fact(n: number): number {
  return n <= 1 ? 1 : n * fact(n - 1);
}
console.log(fact(10)); //> 3628800
function isEven(n: number): boolean {
  return n === 0 ? true : isOdd(n - 1);
}
function isOdd(n: number): boolean {
  return n === 0 ? false : isEven(n - 1);
}
console.log(isEven(10), isOdd(7)); //> true true
const sum = (n: number): number => (n === 0 ? 0 : n + sum(n - 1));
console.log(sum(1000)); //> 500500
