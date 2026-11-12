// Literal types, and unions of them.
type Direction = "up" | "down";
let d: Direction = "up";
console.log(d); //> up
d = "down";
console.log(d); //> down
const one: 1 = 1;
const minus: -1 | 0 = -1;
const yes: true = true;
console.log(one, minus, yes); //> 1 -1 true
let n: number | string = 1;
n = "one";
console.log(n); //> one
let maybe: string | null = null;
console.log(maybe); //> null
maybe = "x";
console.log(maybe); //> x
const list: (number | string)[] = [1, "a", 2];
console.log(list); //> [ 1, 'a', 2 ]
// `const` keeps a literal's type; `let` widens it.
const c = "c";
let w = c;
w = "anything";
console.log(w); //> anything
// A union in a function type.
const pick = (b: boolean): "a" | "b" => (b ? "a" : "b");
console.log(pick(true), pick(false)); //> a b
// A leading `|` is allowed.
type T =
  | { kind: "x" }
  | { kind: "y" };
const t: T = { kind: "y" };
console.log(t); //> { kind: 'y' }
