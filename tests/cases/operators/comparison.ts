console.log(1 < 2, 2 < 1, 1 <= 1, 1 >= 2, 2 > 1); //> true false true false true
console.log("a" < "b", "B" < "a", "abc" < "ab", "10" < "9"); //> true true false true
console.log("\u{1F600}" < "～"); //> true
console.log(0 / 0 < 1, 0 / 0 >= 1, 0 / 0 <= 0 / 0); //> false false false
console.log(true > false, false >= true); //> true false
