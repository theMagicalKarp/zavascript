// Narrowing where a closure is created carries into it when nothing assigns the variable later.
function later(x: string | undefined) {
  if (x !== undefined) {
    return () => x + "!";
  }
  return () => "none";
}
console.log(later("a")(), later(undefined)()); //> a! none
function inside(x: number | null) {
  const f = () => {
    if (x === null) {
      return 0;
    }
    return x + 1;
  };
  return f();
}
console.log(inside(1), inside(null)); //> 2 0
