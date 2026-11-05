let a = 0;
console.log((a++, a++, a)); //> 2
let b = (console.log("first"), "second"); //> first
console.log(b); //> second
for (let i = 0, j = 3; i < j; i++, j--) console.log(i, j);
//> 0 3
//> 1 2
console.log((0, console.log)("indirect")); //> indirect
//> undefined
