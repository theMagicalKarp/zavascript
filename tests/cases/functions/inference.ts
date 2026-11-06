function maybe(x: boolean) {
  if (x) {
    return 1;
  }
}
const a: string = maybe(true); //! TS2322
function loops() {
  while (true) {}
}
const b: string = loops(); //! TS2322
const spins = () => {
  while (true) {}
};
const c: string = spins();
const d: string = (() => "s")();
function widened() {
  return "literal";
}
const e: number = widened(); //! TS2322
const f: number = (x: number) => x; //! TS2322
