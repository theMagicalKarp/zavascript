function counter() {
  let count = 0;
  return () => {
    count += 1;
    return count;
  };
}
const a = counter();
const b = counter();
a();
a();
console.log(a(), b()); //> 3 1
// Each pass through a `for` loop gets its own `i`.
let first = () => -1;
let last = () => -1;
for (let i = 0; i < 3; i++) {
  if (i === 0) {
    first = () => i;
  }
  last = () => i;
}
console.log(first(), last()); //> 0 2
// And a block in a loop gets new variables each time.
let captured = () => "";
let n = 0;
while (n < 3) {
  const label = `pass ${n}`;
  if (n === 1) {
    captured = () => label;
  }
  n++;
}
console.log(captured()); //> pass 1
// Closures share the variable, not a copy of it.
let shared = 1;
const read = () => shared;
shared = 2;
console.log(read()); //> 2
function makeAdder(x: number) {
  function add(y: number) {
    return x + y;
  }
  return add;
}
console.log(makeAdder(10)(5)); //> 15
