// An error from a parameter's default value is thrown from the parameter, not the call.
const nothing: any = null;
function first(
  a: number = nothing.x, //!! TypeError: Cannot read properties of null (reading 'x')
): number {
  return a;
}
console.log("before"); //> before
first();
