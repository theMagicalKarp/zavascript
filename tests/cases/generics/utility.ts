interface Todo {
  title: string;
  done: boolean;
  note?: string;
}
const draft: Partial<Todo> = { title: "write" };
const full: Required<Todo> = { title: "t", done: false, note: "n" };
const frozen: Readonly<Todo> = { title: "f", done: true };
const summary: Pick<Todo, "title" | "done"> = { title: "p", done: false };
const counts: Record<"a" | "b", number> = { a: 1, b: 2 };
console.log(draft, full.note, frozen.title, summary, counts); //> { title: 'write' } n f { title: 'p', done: false } { a: 1, b: 2 }

// Utility types of type parameters.
function update<T>(item: T, changes: Partial<T>): T {
  return item;
}
const todo: Todo = { title: "x", done: false };
console.log(update(todo, { done: true }).title); //> x
function freeze<T>(item: T): Readonly<T> {
  return item;
}
const ro = freeze({ a: 1 });
console.log(ro.a); //> 1

// A mapped type of its own.
type Flags<T> = { [K in keyof T]: boolean };
const flags: Flags<Todo> = { title: true, done: false };
console.log(flags); //> { title: true, done: false }
type Nullable<T> = { [K in keyof T]: T[K] | null };
const nothing: Nullable<{ a: number }> = { a: null };
console.log(nothing); //> { a: null }

// Nothing is required of a `Partial<T>`, whatever `T` is.
function blank<T>(): Partial<T> {
  return {};
}
console.log(blank<Todo>()); //> {}

// Of a union, a mapped type is the union of it for each member.
interface Circle {
  radius: number;
}
interface Square {
  side: number;
}
const shape: Partial<Circle | Square> = {};
const square: Readonly<Circle | Square> = { side: 2 };
console.log(shape, square); //> {} { side: 2 }
