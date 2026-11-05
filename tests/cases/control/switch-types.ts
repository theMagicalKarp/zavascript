let n = 1;
switch (n) {
  case 1:
  case "a": //! TS2678
  case true: //! TS2678
  case null:
  case undefined:
}
const k = 1;
switch (k) {
  case 2: //! TS2678
}
