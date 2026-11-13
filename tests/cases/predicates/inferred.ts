// tsc 5.5 infers a type guard for a function that returns a test of its parameter, which is what
// makes `filter` narrow.
const withNulls = [1, null, 2, undefined, 3];
const present = withNulls.filter((x) => x !== null && x !== undefined);
const sum: number = present.reduce((a, b) => a + b, 0);
console.log(present, sum); //> [ 1, 2, 3 ] 6
const isDefined = (x: string | undefined) => x !== undefined;
const maybe: string | undefined = ["a"][0] as string | undefined;
if (isDefined(maybe)) {
  console.log(maybe.length); //> 1
}
function isEven(n: number) {
  return n % 2 === 0;
}
// A test that isn't about the parameter's type infers nothing.
const evens: number[] = [1, 2, 3, 4].filter(isEven);
console.log(evens); //> [ 2, 4 ]
const strings: string[] = ["a", 1, "b", true].filter((x) => typeof x === "string");
console.log(strings.join("")); //> ab
const truthy = ["", "x", "y"].filter((s) => s);
console.log(truthy); //> [ 'x', 'y' ]
