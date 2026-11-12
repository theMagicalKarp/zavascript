function id<T>(x: T): T {
  return x;
}
function same<T>(a: T, b: T): void {}
same(1, "x"); //! TS2345
id<number>("x"); //! TS2345
id<number, string>(1); //! TS2558
const n: number = id("a"); //! TS2322

function convert<T, U>(x: T): U {
  return x; //! TS2322
}
function prop<T>(x: T) {
  return x.name; //! TS2339
}
function len<T extends { length: number }>(x: T): number {
  return x.length;
}
len(1); //! TS2345
len<number>(1); //! TS2344
function nope(x: U) {} //! TS2304
function dup<T, T>() {} //! TS2300
function circular<T extends T>() {} //! TS2313
function order<T = string, U>() {} //! TS2706
function arith<T>(a: T) {
  return a * 2; //! TS2362
}
function plain(x: number) {}
plain<number>(1); //! TS2558
function none<U>(): U {
  return undefined as any;
}
const leaked = id(none());
const leaked_string: string = leaked; //! TS2322
function again<T>(x: T, n: number) {
  if (n > 0) {
    return again(x, n - 1);
  }
  return x;
}
const again_n: string = again(1, 2); //! TS2322
const wrong: { f: (x: number) => string } = { f: id }; //! TS2322
