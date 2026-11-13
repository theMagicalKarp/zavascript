// JSON.stringify and JSON.parse.
console.log(JSON.stringify({ a: [1, "x", null, true], b: { c: undefined }, d: () => 1 })); //> {"a":[1,"x",null,true],"b":{}}
console.log(JSON.stringify([undefined, NaN, Infinity, -0]), JSON.stringify("he\"llo\n\u0001"), JSON.stringify(undefined)); //> [null,null,null,0] "he\"llo\n\u0001" undefined
console.log(JSON.stringify({ a: 1, b: [1, 2], c: {} }, null, 2));
//> {
//>   "a": 1,
//>   "b": [
//>     1,
//>     2
//>   ],
//>   "c": {}
//> }
console.log(JSON.stringify([1, [2]], null, "--"));
//> [
//> --1,
//> --[
//> ----2
//> --]
//> ]
console.log(JSON.stringify({ a: 1, b: 2, c: 3 }, ["a", "c"]), JSON.stringify({ a: 1, b: "x" }, (key, value) => (typeof value === "number" ? value * 10 : value))); //> {"a":1,"c":3} {"a":10,"b":"x"}
console.log(JSON.stringify(new Map([[1, 2]])), JSON.stringify([new Set([1])]), JSON.stringify({ toJSON: () => "custom" })); //> {} [{}] "custom"
const parsed = JSON.parse('{"a":[1,2,{"b":null}],"c":"\\u00e9\\ud83d\\ude00","d":-1.5e2}');
console.log(parsed, parsed.c.length); //> { a: [ 1, 2, { b: null } ], c: 'é😀', d: -150 } 3
console.log(JSON.parse("1e3"), JSON.parse(' "x" '), JSON.parse("[]"), JSON.parse("true"), JSON.parse("null")); //> 1000 x [] true null
console.log(JSON.parse("[1, 2]", (key, value) => (typeof value === "number" ? value + 1 : value))); //> [ 2, 3 ]
console.log(JSON.parse('{"a":1,"b":2}', (key, value) => (key === "a" ? undefined : value))); //> { b: 2 }
const roundTrip = JSON.parse(JSON.stringify({ when: "now", n: [1.5] }));
console.log(roundTrip); //> { when: 'now', n: [ 1.5 ] }
