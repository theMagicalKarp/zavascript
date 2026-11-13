// Map and Set, which compare keys with SameValueZero and keep insertion order.
const m = new Map<string, number>([["a", 1]]);
m.set("b", 2).set("a", 3);
console.log(m, m.get("a"), m.get("z"), m.has("b"), m.size); //> Map(2) { 'a' => 3, 'b' => 2 } 3 undefined true 2
console.log([...m.keys()], [...m.values()], [...m], [...m.entries()]); //> [ 'a', 'b' ] [ 3, 2 ] [ [ 'a', 3 ], [ 'b', 2 ] ] [ [ 'a', 3 ], [ 'b', 2 ] ]
m.forEach((value, key) => console.log(key, value));
//> a 3
//> b 2
console.log(m.delete("a"), m.delete("a"), m); //> true false Map(1) { 'b' => 2 }
m.clear();
console.log(m, m.size); //> Map(0) {} 0
const anyKeys = new Map<unknown, string>();
anyKeys.set(NaN, "nan").set(-0, "zero").set("1", "string").set(1, "number");
console.log(anyKeys.get(NaN), anyKeys.get(0), anyKeys, new Map()); //> nan zero Map(4) { NaN => 'nan', 0 => 'zero', '1' => 'string', 1 => 'number' } Map(0) {}
const objectKey = { id: 1 };
const byObject = new Map([[objectKey, "found"]]);
console.log(byObject.get(objectKey), byObject.get({ id: 1 })); //> found undefined
const s = new Set([1, 2, 2, 3]);
s.add(4).add(1);
console.log(s, s.size, s.has(2), s.has(9), [...s], new Set("hello"), new Set()); //> Set(4) { 1, 2, 3, 4 } 4 true false [ 1, 2, 3, 4 ] Set(4) { 'h', 'e', 'l', 'o' } Set(0) {}
console.log(s.delete(2), [...s.entries()], [...s.keys()]); //> true [ [ 1, 1 ], [ 3, 3 ], [ 4, 4 ] ] [ 1, 3, 4 ]
const unique = [...new Set(["b", "a", "b"])];
console.log(unique); //> [ 'b', 'a' ]
for (const [key, value] of new Map([["x", 10]])) {
  console.log(key, value); //> x 10
}
for (const value of new Set(["only"])) {
  console.log(value); //> only
}
// Entries added while going through are visited; ones deleted before they're reached aren't.
const live = new Map([[1, "one"], [2, "two"]]);
for (const [key] of live) {
  if (key === 1) {
    live.delete(2);
    live.set(3, "three");
  }
  console.log(key);
//> 1
//> 3
}
const empty = new Map();
const emptySet = new Set();
console.log(empty.size, emptySet.size); //> 0 0
