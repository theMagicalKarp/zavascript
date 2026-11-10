const { a = "x" } = { a: 1 };
const fromA: number = a; //! TS2322
function f({ a = "x" }: { a: number }) {} //! TS2322
function g({ a = "x" }: { a?: number }) {} //! TS2322
const [b = "s"]: [number] = [1]; //! TS2322
const [c, d] = [1]; //! TS2493
const { e } = {}; //! TS2339
const { h = 1 } = {};
const [m = 1, n = "q"] = [];
const { p: [q, r] } = { p: [1, "s"] };
const fromQ: string = q; //! TS2322
let [u = 1] = [];
u = 2;
function implicit({ x, y = 1 }, [z]) {} //! TS7031 TS7031
const [s] = 5; //! TS2488
const { t } = { t: 1, extra: 2 }; //! TS2353
const { t2, ...others } = { t2: 1, extra: 2 };
const [w] = [1, 2];
function excessDefault({ t } = { t: 1, x: 2 }) {} //! TS2353
const { missing }: { present: number } = { present: 1 }; //! TS2339
