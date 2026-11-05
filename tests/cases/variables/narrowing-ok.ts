// Where control flow joins, a variable holds whatever any path left in it.
let found = false;
for (let i = 0; i < 5; i++) {
  if (i === 3) {
    found = true;
  }
}
console.log(found === true); //> true
let done = false;
while (!done) {
  done = true;
}
console.log(done); //> true
let flag = true;
if (found) {
  flag = false;
}
console.log(flag === false); //> true
let n = 1;
let t = typeof n;
console.log(t === "number"); //> true
let mixed = n ? "a" : 1;
mixed = 2;
mixed = "b";
console.log(mixed + 1); //> b1
// `let` widens literals, `const` keeps them.
const one = 1;
let widened = one;
widened = 2;
console.log(widened); //> 2
// Testing a variable whose type isn't a union doesn't narrow it.
let count = 0;
if (count) {
  console.log("never");
} else {
  console.log(count === 0); //> true
}
