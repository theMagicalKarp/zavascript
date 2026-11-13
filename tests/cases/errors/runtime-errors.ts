// The errors the runtime raises are ordinary errors, which can be caught.

function message(f: () => unknown): string {
  try {
    f();
    return "no error";
  } catch (e) {
    return e instanceof Error ? `${e.name}: ${e.message}` : `not an error: ${e}`;
  }
}

const nothing: any = undefined;
console.log(message(() => nothing.x)); //> TypeError: Cannot read properties of undefined (reading 'x')
console.log(message(() => nothing())); //> TypeError: nothing is not a function
console.log(message(() => JSON.parse("{a"))); //> SyntaxError: Expected property name or '}' in JSON at position 1 (line 1 column 2)
console.log(message(() => (1).toFixed(200))); //> RangeError: toFixed() digits argument must be between 0 and 100
console.log(message(() => "x".repeat(-1))); //> RangeError: Invalid count value: -1
console.log(message(() => ([] as number[]).reduce((a, b) => a + b))); //> TypeError: Reduce of empty array with no initial value
console.log(message(() => later)); //> ReferenceError: Cannot access 'later' before initialization
const later = 1;

// Running out of stack is a RangeError too, and the program carries on after it.
function forever(n: number): number {
  return forever(n + 1) + 1;
}
console.log(message(() => forever(0))); //> RangeError: Maximum call stack size exceeded
const nested: any[] = [];
let inner: any[] = nested;
for (let i = 0; i < 100000; i++) {
  const next: any[] = [];
  inner.push(next);
  inner = next;
}
console.log(message(() => JSON.stringify(nested))); //> RangeError: Maximum call stack size exceeded
console.log(message(() => 1)); //> no error

// `instanceof` needs something with a prototype.
const arrow = () => 1;
function declared() {}
const notCallable: any = {};
const primitive: any = 1;
console.log(message(() => ({}) instanceof arrow)); //> TypeError: Function has non-object prototype 'undefined' in instanceof check
console.log(message(() => ({}) instanceof notCallable)); //> TypeError: Right-hand side of 'instanceof' is not callable
console.log(message(() => ({}) instanceof primitive)); //> TypeError: Right-hand side of 'instanceof' is not an object
console.log(({}) instanceof declared, (1 as any) instanceof Number); //> false false

// A `finally` still runs when the stack runs out.
let cleaned = 0;
function guarded(n: number): number {
  try {
    return guarded(n + 1);
  } finally {
    cleaned++;
  }
}
console.log(message(() => guarded(0)), cleaned > 1000); //> RangeError: Maximum call stack size exceeded true
