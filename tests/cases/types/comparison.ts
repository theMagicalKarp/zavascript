console.log("a" < 1); //! TS2365
console.log(1 < "a" < 2); //! TS2365 TS2365
console.log(null < 1); //! TS18050
console.log(console.log() < 1); //! TS2365
console.log(1 === "a"); //! TS2367
console.log(1 === 2); //! TS2367
console.log("a" !== "b"); //! TS2367
console.log(true === 1); //! TS2367
console.log(1 == "1"); //! TS2367
console.log(typeof 1 === "nope"); //! TS2367
console.log(NaN === 1); //! TS2845
console.log(1 !== NaN); //! TS2845
console.log(1 != 2); //! TS2367
console.log("a" !== "b"); //! TS2367
