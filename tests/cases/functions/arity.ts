function two(a: number, b: string) {}
two(1); //! TS2554
two(1, "b", 3); //! TS2554
function optional(a: number, b?: string, c = 1) {}
optional(); //! TS2554
optional(1, "b", 2, 3); //! TS2554
function rest(a: number, ...r: number[]) {}
rest(); //! TS2555
rest(1, "x"); //! TS2345
function none() {}
none(1); //! TS2554
two("a", "b"); //! TS2345
optional(1, undefined, undefined);
