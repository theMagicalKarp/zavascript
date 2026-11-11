function reassigned(x: string | undefined) {
  if (x !== undefined) {
    const f = () => x + 1; //! TS18048
    x = undefined;
  }
}
function declaration(x: string | undefined) {
  if (x !== undefined) {
    function f() {
      return x + 1; //! TS18048
    }
  }
}
