// What tsc reports about using strings' methods wrongly.
const s = "text";
s.charAt("0"); //! TS2345
s.foo; //! TS2339
s.isWellFormed(); //! TS2550
s.split(1); //! TS2769
s.replace("t", 5); //! TS2769
s.padStart(); //! TS2554
const n: number = s.toUpperCase(); //! TS2322
s[0] = "T"; //! TS2542
s.length = 3; //! TS2540
String.fromCharCode("a"); //! TS2345
