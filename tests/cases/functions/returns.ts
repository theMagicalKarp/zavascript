function noReturn(): number {} //! TS2355
function maybe(x: boolean): number { //! TS2366
  if (x) {
    return 1;
  }
}
function wrong(): number {
  return "x"; //! TS2322
}
function empty(): number {
  return; //! TS2322
}
function voidy(): void {
  return 1; //! TS2322
}
function never(): never {} //! TS2534
function fine(): void {}
function undef(): undefined {}
function anything(): any {}
function infinite(): number {
  while (true) {}
}
return 1; //! TS1108
