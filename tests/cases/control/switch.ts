function_like: for (let n = 0; n < 5; n++) {
  switch (n) {
    case 0:
      console.log("zero");
      break;
    case 1:
    case 2:
      console.log("one or two", n);
      break;
    case 3:
      console.log("three, falling through");
    default:
      console.log("default", n);
  }
}
//> zero
//> one or two 1
//> one or two 2
//> three, falling through
//> default 3
//> default 4
// `default` can come first, and still only runs when nothing matches.
let s = "b";
switch (s) {
  default:
    console.log("default");
  case "a":
    console.log("a");
    break;
  case "b":
    console.log("b"); //> b
}
switch (s + s) {
  default:
    console.log("default"); //> default
  case "a":
    console.log("a"); //> a
}
// Cases are compared with `===`.
let n = 0;
switch (n) {
  case -0:
    console.log("negative zero matches"); //> negative zero matches
}
// `continue` inside a switch continues the enclosing loop.
for (let i = 0; i < 3; i++) {
  switch (i) {
    case 1:
      continue;
  }
  console.log(i);
}
//> 0
//> 2
