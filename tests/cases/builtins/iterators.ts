// The builtin iterators: what entries(), keys() and values() return, and next().
const it = [10, 20].values();
console.log(it.next(), it.next(), it.next()); //> { value: 10, done: false } { value: 20, done: false } { value: undefined, done: true }
const mapIterator = new Map([["a", 1], ["b", 2]]).keys();
mapIterator.next();
console.log(mapIterator, [...mapIterator], mapIterator); //> [Map Iterator] {  } [ 'b' ] [Map Iterator] {  }
console.log([1].entries(), new Set([1]).values(), new Map([[1, 2]]).entries(), new Set([1]).entries()); //> Object [Array Iterator] {} [Set Iterator] { 1 } [Map Entries] { [ 1, 2 ] } [Set Entries] { [ 1, 1 ] }
// Destructuring takes values from an iterator.
const [first, ...rest] = new Set(["x", "y", "z"]);
console.log(first, rest); //> x [ 'y', 'z' ]
const [a, b] = "hi";
console.log(a, b); //> h i
const [[k, v]] = new Map([["key", "value"]]);
console.log(k, v); //> key value
console.log(Math.max(...new Set([3, 9, 1])), [..."ab", ...new Set([1])]); //> 9 [ 'a', 'b', 1 ]
