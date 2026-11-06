function apply(f: (n: number) => number) {}
apply((x) => "s"); //! TS2322
apply((x: string) => 1); //! TS2345
const more: (a: number) => void = (a, b) => {}; //! TS2322 TS7006 TS7006
let f: (n: number) => number = (n) => n;
f = () => "s"; //! TS2322
f = (n: string) => 1; //! TS2322
const g: (n: number) => void = (n) => {
  const s: string = n; //! TS2322
};
