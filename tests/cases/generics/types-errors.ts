interface Box<T> {
  value: T;
}
const a: Box = { value: 1 }; //! TS2314
const b: Box<number, string> = { value: 1 }; //! TS2314
const c: Box<number> = { value: "x" }; //! TS2322
type Plain = { a: number };
const d: Plain<number> = { a: 1 }; //! TS2315
type Two<A, B = A> = [A, B];
const e: Two = [1, 1]; //! TS2707
interface Lengthy<T extends { length: number }> {
  item: T;
}
const f: Lengthy<number> = { item: 1 }; //! TS2344
const g: Array<number, string> = []; //! TS2314
const h: Box<number> = { value: 1 };
const i: Box<string> = h; //! TS2322
type Loop<T> = Loop<T>; //! TS2456 TS2315
type Wrapped<T> = { value: T };
type Again<T> = Wrapped<Again<T>>; //! TS2456 TS2315
type Ping<T> = Pong<T>; //! TS2456 TS2315
type Pong<T> = Ping<T>; //! TS2456 TS2315
interface Ranked<T extends Ranked<T>> {
  rank: number;
}
interface Unranked extends Ranked<Unranked> {}
interface Misranked extends Ranked<number> {} //! TS2344
interface Self<T extends { id: number } = Self<{ id: 1 }>> {} //! TS2344
