// Object and Object.prototype.
const o = { b: 2, a: 1, 1: "one", 0: "zero" };
console.log(Object.keys(o), Object.values(o), Object.entries(o)); //> [ '0', '1', 'b', 'a' ] [ 'zero', 'one', 2, 1 ] [ [ '0', 'zero' ], [ '1', 'one' ], [ 'b', 2 ], [ 'a', 1 ] ]
console.log(Object.keys([5, 6]), Object.values("ab"), Object.entries({})); //> [ '0', '1' ] [ 'a', 'b' ] []
const merged = Object.assign({ a: 1 }, { b: "x" }, { c: true });
const sum: number = merged.a + (merged.c ? 1 : 0);
console.log(merged, sum, Object.assign({ a: 1 }, { a: 2 })); //> { a: 1, b: 'x', c: true } 2 { a: 2 }
const frozen = Object.freeze({ a: 1, nested: { b: 2 } });
frozen.nested.b = 3;
console.log(frozen, Object.isFrozen(frozen), Object.isFrozen({}), Object.isFrozen(5)); //> { a: 1, nested: { b: 3 } } true false true
const fromEntries = Object.fromEntries([["k", 1], ["j", 2]]);
const k: number = fromEntries.k;
console.log(fromEntries, k, Object.fromEntries(new Map([["m", true]]))); //> { k: 1, j: 2 } 1 { m: true }
console.log(Object.hasOwn({ a: 1 }, "a"), Object.hasOwn({ a: 1 }, "b"), ({ a: 1 }).hasOwnProperty("a"), [1].hasOwnProperty(0)); //> true false true true
console.log(({}).toString(), String({}), `${[1, 2]}`, ({ x: 1 }).valueOf()); //> [object Object] [object Object] 1,2 { x: 1 }
const record: Record<string, number> = { one: 1 };
record.two = 2;
record["three"] = 3;
console.log(record, Object.keys(record).length); //> { one: 1, two: 2, three: 3 } 3
const counts: { [word: string]: number } = {};
for (const word of ["a", "b", "a"]) {
  counts[word] = (counts[word] ?? 0) + 1;
}
console.log(counts); //> { a: 2, b: 1 }
