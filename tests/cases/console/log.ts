console.log(); //>
console.log("a", 1, true, null, undefined); //> a 1 true null undefined
console.log(console.log, console.error); //> [Function: log] [Function: error]
console.info("info", "and", "more"); //> info and more
console.debug(1); //> 1
console.log(typeof console.log, typeof console, typeof null, typeof undefined); //> function object object undefined
console.log(typeof "", typeof 0, typeof false); //> string number boolean
