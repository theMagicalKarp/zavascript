interface Point {
  x: number;
  y: number;
}
const k: keyof Point = "z"; //! TS2322
type Z = Point["z"]; //! TS2339
function get<T, K>(o: T, key: K): T[K] { //! TS2536
  return o[key]; //! TS2536
}
function get2<T, K extends keyof T>(o: T, key: K) {}
get2({ a: 1 }, "b"); //! TS2345
const t: typeof missing = 1; //! TS2304
type Third = [number, string][2]; //! TS2493
