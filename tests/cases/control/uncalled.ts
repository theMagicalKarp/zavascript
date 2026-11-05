// Testing a function instead of calling it.
if (console.log) {} //! TS2774
console.log ? 1 : 2; //! TS2774
console.log && 1; //! TS2774
let f = console.log;
if (f) {} //! TS2774
if (f || console.log) {} //! TS2774 TS2774
// Using it in the body, or later in an `&&` chain, means it's tested on purpose.
if (console.log) {
  console.log("ok");
}
console.log && console.log("ok");
console.log ? console.log("ok") : 0;
if (f && 1) {
  f();
}
while (console.log) {
  break;
}
