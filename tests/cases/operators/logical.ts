console.log(1 && 2, 0 && 2, 1 || 2, 0 || 2); //> 2 0 1 2
console.log((1 - 1) || "fallback", (2 - 1) && "second"); //> fallback second
console.log(!(1 - 1), !(2 > 1)); //> true false
console.log(NaN ?? 1); //> NaN
console.log(console.log() ?? "default");
//>
//> default
// The right side isn't evaluated when it isn't needed.
console.log(0 && console.log("never"), 1 || console.log("never")); //> 0 1
console.log((1 < 2) ? "yes" : "no", (1 > 2) ? "yes" : "no"); //> yes no
console.log(true ? 1 : 0 ? 2 : 3); //> 1
