// An error the runtime raises ends the program, once what it printed is out.
console.log("before"); //> before
function read(o: any): unknown {
  return o.missing.x; //!! TypeError: Cannot read properties of undefined (reading 'x')
}
read({});
console.log("never");
