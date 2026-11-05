let n = 3;
if (n > 2) console.log("big"); //> big
if (n > 5) {
  console.log("never");
} else if (n > 1) {
  console.log("middle"); //> middle
} else {
  console.log("never");
}
if (n === 0) console.log("zero");
else console.log("not zero"); //> not zero
// A dangling `else` goes with the nearest `if`.
if (n > 0) if (n > 10) console.log("a"); else console.log("b"); //> b
let s = "";
if (s) console.log("never");
if (!s) console.log("empty"); //> empty
