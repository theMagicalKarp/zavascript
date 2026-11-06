function f() {}
f = () => {}; //! TS2630
const g = function h() {
  h = () => {}; //! TS2630
};
const k = () => {};
k = () => {}; //! TS2588
function dup() {} //! TS2393
function dup() {} //! TS2393
let x = 1; //! TS2300
function x() {} //! TS2300
function params(a: number, a: string) {} //! TS2300 TS2300
function body(a: number) { //! TS2300
  let a = 1; //! TS2300
}
