console.log(a); //! TS2448 TS2454
let a = 1;
b = 2; //! TS2448
let b = 0;
let c: number = c; //! TS2448 TS2454
{
  console.log(d); //! TS2448
  const d: any = 1;
}
