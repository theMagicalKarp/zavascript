// Type predicates have to be about a parameter, with a type it could be.
function isString(x: number): x is string { //! TS2677
  return true;
}
function wrongName(x: unknown): y is string { //! TS1225
  return true;
}
const n: number | string = 1 as number | string;
function isNumber(x: unknown): x is number {
  return typeof x === "number";
}
if (!isNumber(n)) {
  const s: number = n; //! TS2322
}
const notAGuard = (x: string | number) => x;
const filtered: number[] = [1, "a"].filter(notAGuard); //! TS2322
function isStrings(...xs: unknown[]): xs is string[] { //! TS1229
  return true;
}
