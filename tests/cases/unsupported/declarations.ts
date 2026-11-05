// Syntax that isn't implemented yet is a ZV9001 error, never silently wrong.
var x = 1; //! ZV9001
function f() { //! ZV9001
  return 1;
}
type T = number; //! ZV9001
console.log([1, 2]); //! ZV9001
console.log({}); //! ZV9001
console.log((a: number) => a); //! ZV9001
