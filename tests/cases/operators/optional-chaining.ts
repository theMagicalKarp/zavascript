interface Node { value: number; next?: Node; visit?: (n: number) => number }
const list: Node = { value: 1, next: { value: 2, visit: (n) => n * 10 } };
console.log(list.next?.value); //> 2
console.log(list.next?.next?.value); //> undefined
// The whole chain short-circuits, not just the link after `?.`.
console.log(list.next?.next?.next?.value); //> undefined
const none = undefined as Node | undefined;
const box = undefined as { inner: { value: number } } | undefined;
console.log(box?.inner.value); //> undefined
// Optional calls and element access.
console.log(list.next?.visit?.(3), list.visit?.(3)); //> 30 undefined
const grid: number[][] | null = [[1, 2]];
console.log(grid?.[0]?.[1]); //> 2
const nothing: number[][] | null = null;
console.log(nothing?.[0][1]); //> undefined
// With `??`.
console.log(list.next?.next?.value ?? "default"); //> default
// Parentheses end a chain.
const maybe: { a?: { b: number } } = { a: { b: 7 } };
console.log((maybe.a?.b)); //> 7
// A function call in a chain runs once, and not at all when the chain stops before it.
let calls = 0;
function get(): Node | undefined {
  calls++;
  return calls > 1 ? undefined : list;
}
console.log(get()?.value, get()?.value, calls); //> 1 undefined 2
console.log(none?.visit?.(calls++), calls); //> undefined 2
