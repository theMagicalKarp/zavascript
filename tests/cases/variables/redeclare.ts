let a = 1; //! TS2451
let a = 2; //! TS2451
const b = 1, c = 2, b = 3; //! TS2451 TS2451
{
  let a = 3;
  console.log(a, b, c);
}
