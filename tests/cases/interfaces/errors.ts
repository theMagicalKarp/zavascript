interface A {
  a: number; //! TS2300
  a: string; //! TS2300 TS2717
  untyped; //! TS7008
  method(); //! TS7010
}
interface B extends Missing { //! TS2304
  b: number;
}
interface C extends A { //! TS2430
  a: string;
}
type T = { t: number }; //! TS2300
type T = string; //! TS2300
const v = 1;
let usesValue: v; //! TS2749
let unknownType: Nope; //! TS2304
type Loop = Loop[]; //! ZV9001
type Direct = Direct; //! TS2456
interface Merged {
  x: number;
}
interface Merged { //! ZV9001
  y: number;
}
