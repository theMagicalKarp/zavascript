const xs = [1, 2, 3];
const s: string = xs[0]; //! TS2322
xs["0"];
xs["key"]; //! TS7015
const k: string = "0";
xs[k]; //! TS7015
const pair: [number, string] = [1, "a"];
pair[2]; //! TS2493
pair[-1]; //! TS2514
const short: [number, string] = [1]; //! TS2322
const long: [number] = [1, 2]; //! TS2322
const wrongElement: [number, string] = [1, 2]; //! TS2322
const fromArray: [number] = xs; //! TS2322
const arr: number[] = [1, "x", 3]; //! TS2322
const nested: number[][] = [[1], ["a"]]; //! TS2322
pair.length = 3; //! TS2322
xs.length = 0; //! ZV9001
xs.push(4); //! ZV9001
let empty = []; //! ZV9001
