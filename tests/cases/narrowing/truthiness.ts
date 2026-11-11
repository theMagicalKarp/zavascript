function name(n: string | undefined) {
  if (n) {
    return n;
  }
  return "anonymous";
}
console.log(name("Ada"), name(undefined), name("")); //> Ada anonymous anonymous
function count(c: number | null) {
  return c ? c + 1 : 0;
}
console.log(count(1), count(0), count(null)); //> 2 0 0
// `&&`, `||` and `!` carry narrowing to their right side.
function first(xs: number[] | undefined) {
  return xs && xs.length > 0 && xs[0];
}
console.log(first([5]), first([]), first(undefined)); //> 5 false undefined
function fallback(s: string | null) {
  return !s || s + "!";
}
console.log(fallback(null), fallback("hi")); //> true hi!
function loop(start: number | undefined) {
  let n = start;
  let steps = 0;
  while (n) {
    n = n - 1;
    steps++;
  }
  return steps;
}
console.log(loop(3), loop(undefined)); //> 3 0
// `unknown` that's truthy is `{}`.
function truthy(u: unknown) {
  if (u) {
    const o: {} = u;
    return o;
  }
  return "falsy";
}
console.log(truthy(1), truthy(0)); //> 1 falsy
