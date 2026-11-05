// Variables that hold `null`, `undefined` or `unknown` can't be used as operands.
let a: null = null;
let b: undefined = undefined;
let c: unknown = 1;
let d: any = 1;
a + 1; //! TS18047
-b; //! TS18048
c * 2; //! TS18046
c < 1; //! TS18046
c++; //! TS18046
c.x; //! TS18046
(c)(); //! TS2571
d * 2;
c === 1;
!c;
typeof c;
