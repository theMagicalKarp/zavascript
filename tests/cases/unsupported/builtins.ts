// Builtins JavaScript has that we don't yet. Using one is an error, never quietly something else.
const d = new Date(); //! ZV9001
[1].toLocaleString(); //! ZV9001
"a".localeCompare("b"); //! ZV9001
(1).toLocaleString(); //! ZV9001
new Number(1); //! ZV9001
Object.create(null); //! ZV9001
Symbol.iterator; //! ZV9001
const e = new Error("x"); //! ZV9001
Promise.resolve(); //! ZV9001
String.raw; //! ZV9001
new Array(3); //! ZV9001
