// Throwing and catching in a loop, from a few calls deep: building each error's stack trace and
// unwinding to the `catch`.
function check(n: number, depth: number): number {
  if (depth > 0) {
    return check(n, depth - 1);
  }
  if (n % 3 === 0) {
    throw new RangeError("multiple of three: " + n);
  }
  return n;
}
let caught = 0;
let total = 0;
for (let i = 0; i < 20000; i++) {
  try {
    total += check(i, 5);
  } catch (e) {
    if (e instanceof RangeError) {
      caught++;
    }
  } finally {
    total++;
  }
}
console.log(caught, total);
