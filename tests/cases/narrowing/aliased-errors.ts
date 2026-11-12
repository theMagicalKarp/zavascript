function f(x: string | number, y: string | number) {
  const isString = typeof x === "string";
  if (isString) {
    const n: number = x; //! TS2322
  }
  // Only a `const` without a type annotation is an aliased condition.
  let isStringToo = typeof x === "string";
  if (isStringToo) {
    const s: string = x; //! TS2322
  }
  const annotated: boolean = typeof x === "string";
  if (annotated) {
    const s: string = x; //! TS2322
  }
  // And only what can't have changed since is narrowed by it.
  const yIsString = typeof y === "string";
  y = 1;
  if (yIsString) {
    const s: string = y; //! TS2322
  }
}
function g(o: { a?: number }, r: { readonly a?: number }) {
  const hasA = o.a !== undefined;
  if (hasA) {
    o.a + 1; //! TS18048
  }
  const hasR = r.a !== undefined;
  if (hasR) {
    r.a + 1;
  }
}
