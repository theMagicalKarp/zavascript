// A constraint gives a type parameter the properties of what it extends.
function len<T extends { length: number }>(x: T): number {
  return x.length;
}
console.log(len([1, 2, 3]), len({ length: 5, extra: true })); //> 3 5

interface Named {
  name: string;
}
function greet<T extends Named>(x: T): string {
  return "hi " + x.name;
}
console.log(greet({ name: "ada", age: 36 })); //> hi ada

// Operators see the constraint.
function add<T extends number>(a: T, b: T): number {
  return a + b;
}
console.log(add(1, 2)); //> 3

// A literal is kept for a primitive constraint.
function tag<T extends string>(t: T): { tag: T } {
  return { tag: t };
}
const t: { tag: "x" } = tag("x");
console.log(t); //> { tag: 'x' }

// Defaults.
function make<T = string>(): T[] {
  return [];
}
const made = make();
const strings: string[] = made;
console.log(strings); //> []

// One type parameter constrained by another.
function assign<T, U extends T>(target: T, value: U): T {
  return value;
}
console.log(assign<number | string, number>(1, 2)); //> 2
