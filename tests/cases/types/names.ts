console.log(foo); //! TS2304
nope(); //! TS2304
console.nope(); //! TS2339
console.log.x; //! TS2339
console.log(1()); //! TS2349
console.log("a"()); //! TS2349
console.log(1)(2); //! TS2349
