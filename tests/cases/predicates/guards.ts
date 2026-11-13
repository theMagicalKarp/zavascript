// Type guards: functions whose return type says what their argument is when they return true.
function isString(x: unknown): x is string {
  return typeof x === "string";
}
const values: unknown[] = ["a", 1, "b"];
for (const v of values) {
  if (isString(v)) {
    console.log(v.toUpperCase());
//> A
//> not a string: 1
  } else {
    console.log("not a string:", v); //> B
  }
}
const isNumber = (x: string | number): x is number => typeof x === "number";
const mixed: (string | number)[] = [1, "two", 3];
const numbers: number[] = mixed.filter(isNumber);
console.log(numbers, mixed.filter((x): x is string => typeof x === "string").map((s) => s.length)); //> [ 1, 3 ] [ 3 ]
const found = mixed.find(isNumber);
console.log(found === undefined ? "none" : found + 1); //> 2
interface Cat {
  meow(): string;
}
interface Dog {
  bark(): string;
}
function isCat(pet: Cat | Dog): pet is Cat {
  return "meow" in pet;
}
const pets: (Cat | Dog)[] = [{ meow: () => "meow" }, { bark: () => "woof" }];
for (const pet of pets) {
  console.log(isCat(pet) ? pet.meow() : pet.bark());
//> meow
//> woof
}
