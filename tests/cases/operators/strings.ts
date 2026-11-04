// `+` concatenates as soon as either side is a string.
console.log("a" + "b" + 1 + 2); //> ab12
console.log(1 + 2 + "a"); //> 3a
console.log("n:" + null + "," + undefined + "," + true); //> n:null,undefined,true
console.log("x" + 0.1 * 3); //> x0.30000000000000004
console.log("" + -0); //> 0
