// What tsc reports about using arrays' methods wrongly.
const xs = [1, 2, 3];
xs.push("4"); //! TS2345
xs.map((x: string) => x); //! TS2345
const s: string = xs.map((x) => x * 2); //! TS2322
xs.reduce((a, b) => a + b, "");
xs.concat("a"); //! TS2769
xs.frobnicate(); //! TS2339
xs.findLast((x) => x > 1); //! TS2550 TS7006
xs.toSorted(); //! TS2550
xs.slice(1, 2, 3); //! TS2554
xs.splice(); //! TS2555
xs.indexOf("2"); //! TS2345
const first: number = xs.find((x) => x > 1); //! TS2322
const ro: readonly number[] = xs;
ro.push(4); //! TS2339
ro[0] = 1; //! TS2542
const strings: string[] = [1, null].filter((x) => x !== null); //! TS2322
[1, 2].forEach((x) => x.toFixed(), 5, 6); //! TS2554
Array.from(5); //! TS2769
const tuple: [number, string] = [1, "a"];
const n: number = tuple.map((x) => x)[0]; //! TS2322
