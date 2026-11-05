// Blocks introduce scopes; an inner declaration shadows an outer one.
let x = "outer";
{
  let x = "inner";
  console.log(x); //> inner
  {
    const x = "innermost";
    console.log(x); //> innermost
  }
  console.log(x); //> inner
}
console.log(x); //> outer
for (let x = 0; x < 2; x++) {
  console.log(x);
}
//> 0
//> 1
console.log(x); //> outer
switch (x) {
  case "outer":
    let x2 = "case scope";
    console.log(x2); //> case scope
}
