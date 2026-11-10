console.log({ a: { b: { c: { d: 1 } } } }); //> { a: { b: { c: [Object] } } }
console.log([[[[1]]]], [[[]]]); //> [ [ [ [Array] ] ] ] [ [ [] ] ]
console.log({ list: [1, 2, 3], nested: [{ a: 1 }, { b: [2] }] }); //> { list: [ 1, 2, 3 ], nested: [ { a: 1 }, { b: [Array] } ] }
console.log({ name: "a fairly long name here", other: "another long string", more: 12345, yes: true }); //> {
//>   name: 'a fairly long name here',
//>   other: 'another long string',
//>   more: 12345,
//>   yes: true
//> }
console.log({ outer: { name: "a fairly long name here", other: "another long string", more: 1 } }); //> {
//>   outer: {
//>     name: 'a fairly long name here',
//>     other: 'another long string',
//>     more: 1
//>   }
//> }
console.log([{ a: 1, b: 2 }, { a: 3, b: 4 }, { a: 5, b: 6 }, { a: 7, b: 8 }, { a: 9, b: 10 }]); //> [
//>   { a: 1, b: 2 },
//>   { a: 3, b: 4 },
//>   { a: 5, b: 6 },
//>   { a: 7, b: 8 },
//>   { a: 9, b: 10 }
//> ]
console.log([["a", 1], ["b", 2], ["c", 3], ["d", 4], ["e", 5], ["f", 6], ["g", 7]]); //> [
//>   [ 'a', 1 ],
//>   [ 'b', 2 ],
//>   [ 'c', 3 ],
//>   [ 'd', 4 ],
//>   [ 'e', 5 ],
//>   [ 'f', 6 ],
//>   [ 'g', 7 ]
//> ]
console.log([[1, 2], [2, 3], [3, 4], [4, 5], [5, 6], [6, 7], [7, 8]]); //> [
//>   [ 1, 2 ], [ 2, 3 ],
//>   [ 3, 4 ], [ 4, 5 ],
//>   [ 5, 6 ], [ 6, 7 ],
//>   [ 7, 8 ]
//> ]
console.log({ text: "first line\nsecond line\nthird line, which is quite a bit longer than the rest" }); //> {
//>   text: 'first line\n' +
//>     'second line\n' +
//>     'third line, which is quite a bit longer than the rest'
//> }
console.log(["x"], [undefined, null], [() => 1], { f() {} }); //> [ 'x' ] [ undefined, null ] [ [Function (anonymous)] ] { f: [Function: f] }
