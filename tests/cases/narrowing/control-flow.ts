// An early `return` or `throw` narrows what comes after it.
function double(x: number | undefined) {
  if (x === undefined) {
    return 0;
  }
  return x * 2;
}
console.log(double(2), double(undefined)); //> 4 0
function strict(x: string | null) {
  if (x === null) {
    throw "no value";
  }
  return x + "!";
}
console.log(strict("ok")); //> ok!
// So does calling a function declared to return `never`.
function fail(message: string): never {
  throw message;
}
function checked(x: number | null): number {
  if (x === null) {
    fail("null");
  }
  return x + 1;
}
console.log(checked(1)); //> 2
const abort: (message: string) => never = (message) => {
  throw message;
};
function checkedToo(x: number | null): number {
  if (x === null) {
    abort("null");
  }
  return x;
}
console.log(checkedToo(5)); //> 5
// Narrowing holds across loops, and joins where control flow does.
function walk(start: number) {
  let current: number | null = start;
  let seen = 0;
  while (current !== null) {
    seen += current;
    current = current > 1 ? current - 1 : null;
  }
  return seen;
}
console.log(walk(3)); //> 6
function join(flag: boolean) {
  let x: string | number | boolean = flag;
  if (flag) {
    x = "yes";
  } else {
    x = 0;
  }
  const y: string | number = x;
  return y;
}
console.log(join(true), join(false)); //> yes 0
