type Direction = "up" | "down";
let d: Direction = "left"; //! TS2322
const one: 1 = 2; //! TS2322
let n: number | string = true; //! TS2322
n = null; //! TS2322
const maybe: string | undefined = 1; //! TS2322
const d2: Direction = "up";
console.log(d2 === "down"); //! TS2367
function f(x: string | number) {
  x - 1; //! TS2362
  x < 1; //! TS2365
  x + 1; //! TS2365
  const s: string = x; //! TS2322
}
interface A { a: number; both: string }
interface B { b: number; both: string }
function g(x: A | B) {
  console.log(x.both);
  x.a; //! TS2339
}
function h(x: (() => void) | number) {
  x(); //! TS2349
}
function k(x: (() => void) | undefined, y: (() => void) | null) {
  x(); //! TS2722
  y(); //! TS2721
}
