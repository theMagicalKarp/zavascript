console.log("a" * 2); //! TS2362
console.log(2 - "a"); //! TS2363
console.log("a" / "b"); //! TS2362 TS2363
console.log(1 / "a" * "b"); //! TS2363 TS2363
console.log(true + 1); //! TS2365
console.log(true % false); //! TS2362 TS2363
console.log(null * 1); //! TS18050
console.log(1 + undefined); //! TS18050
console.log(-null); //! TS18050
console.log(void 0 * 1); //! TS2532
console.log(console.log() * 1); //! TS2362
console.log(console.log() + 1); //! TS2365
console.log(!(1 - 1) + 1); //! TS2365
