function later(a = b, b = 1) {} //! TS2373
function itself(a = a) {} //! TS7022 TS2372
function wrongDefault(a: number = "s") {} //! TS2322
function rest(...r: number) {} //! TS2370
function order(a?: number, b: number) {} //! TS1016
