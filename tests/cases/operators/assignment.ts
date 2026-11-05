let a = 10;
console.log(a = 3, a); //> 3 3
let b = 0, c = 0;
b = c = 7;
console.log(b, c); //> 7 7
a += 2; console.log(a); //> 5
a -= 1; console.log(a); //> 4
a *= 3; console.log(a); //> 12
a /= 8; console.log(a); //> 1.5
a %= 1; console.log(a); //> 0.5
a = 2;
a **= 10; console.log(a); //> 1024
a <<= 2; console.log(a); //> 4096
a >>= 3; console.log(a); //> 512
a = -16;
a >>>= 28; console.log(a); //> 15
a &= 6; console.log(a); //> 6
a |= 9; console.log(a); //> 15
a ^= 5; console.log(a); //> 10
let s = "x";
s += 1;
s += true;
console.log(s); //> x1true
// The logical assignments only assign, and only evaluate the right side, when they need to.
let n = 0;
n ||= 5; console.log(n); //> 5
n ||= (console.log("never"), 6); console.log(n); //> 5
n &&= 0; console.log(n); //> 0
n &&= (console.log("never"), 7); console.log(n); //> 0
