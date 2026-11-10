function* gen() {} //! ZV9001
async function af() {} //! ZV9001
const aa = async () => 1; //! ZV9001
function withThis(this: number) {} //! ZV9001
let ctor: new () => void; //! ZV9001
let generic: <T>(x: T) => T; //! ZV9001
function overload(a: number): void; //! ZV9001
function overload(a: number) {}
