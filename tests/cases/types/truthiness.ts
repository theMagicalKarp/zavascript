// tsc rejects conditions whose truthiness is obvious from the syntax.
console.log("a" || 1); //! TS2872
console.log("" || 1); //! TS2873
console.log(5 || 1); //! TS2872
console.log(`` || 1); //! TS2873
console.log(null || 1); //! TS2873
console.log(undefined && 1); //! TS2873
console.log(void 0 || 1); //! TS2873
console.log(((("a"))) || 2); //! TS2872
console.log(!"a"); //! TS2872
console.log(2 ? 1 : 0); //! TS2872
console.log(1 ?? 2); //! TS2869
console.log("a" ?? 2); //! TS2869
console.log((1 + 2) ?? 1); //! TS2869
console.log(null ?? 2); //! TS2871
console.log(undefined ?? 2); //! TS2871
