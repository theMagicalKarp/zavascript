// A spread argument has to be a tuple, or be for a rest parameter.
function pair(a: number, b: number) {
  return a + b;
}
const xs = [1, 2];
pair(...xs); //! TS2556
Math.max(...5); //! TS2488
function rest(...ns: number[]) {
  return ns;
}
rest(...["a"]); //! TS2345
const t: [number, number, number] = [1, 2, 3];
pair(...t); //! TS2554
