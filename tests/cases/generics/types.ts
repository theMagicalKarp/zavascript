interface Box<T> {
  value: T;
}
const b: Box<number> = { value: 1 };
const s: Box<string> = { value: "s" };
console.log(b.value + 1, s.value); //> 2 s

// Recursive generic interfaces.
interface List<T> {
  head: T;
  tail?: List<T>;
}
const list: List<number> = { head: 1, tail: { head: 2 } };
console.log(list.tail?.head); //> 2

// Generic type aliases, of object types and of others.
type Pair<T> = { left: T; right: T };
type Maybe<T> = T | null;
const pair: Pair<string> = { left: "l", right: "r" };
const maybe: Maybe<number> = null;
console.log(pair.left, maybe); //> l null

// Defaults, and type parameters that refer to earlier ones.
type Result<T, E = string> = { ok: true; value: T } | { ok: false; error: E };
const ok: Result<number> = { ok: true, value: 1 };
const failed: Result<number> = { ok: false, error: "no" };
function show<T>(r: Result<T>): string {
  return r.ok ? "ok" : r.error;
}
console.log(show(ok), show(failed)); //> ok no

// Extending a generic interface.
interface Labeled<T> extends Box<T> {
  label: string;
}
const labeled: Labeled<boolean> = { value: true, label: "flag" };
const box: Box<boolean> = labeled;
console.log(box.value); //> true

// Generic functions taking generic types, inferring through them.
function unbox<T>(b: Box<T>): T {
  return b.value;
}
const n: number = unbox(b);
console.log(n); //> 1
function orElse<T>(m: Maybe<T>, fallback: T): T {
  return m === null ? fallback : m;
}
console.log(orElse(maybe, 7)); //> 7

// `Array<T>` is `T[]`.
const arr: Array<number> = [1, 2];
const same: number[] = arr;
console.log(same); //> [ 1, 2 ]

// Generic methods and function types.
interface Mapper {
  map<T>(x: T): T[];
}
const m: Mapper = { map: (x) => [x] };
const wrap: <T>(x: T) => T[] = (x) => [x];
console.log(m.map(1), wrap("w")); //> [ 1 ] [ 'w' ]

// A type parameter's constraint can refer to the type it's declared on.
interface Ordered<T extends Ordered<T>> {
  rank: number;
  next?: T;
}
interface Card extends Ordered<Card> {
  name: string;
}
type Linked<T extends Linked<any>> = { item: number; next?: T };
const card: Card = { rank: 1, name: "ace" };
const link: Linked<Linked<any>> = { item: 1, next: { item: 2 } };
console.log(card.name, link.next?.item); //> ace 2
