const s = { toString() { return "s"; } }; //! ZV9001
const v = { valueOf: () => 1 }; //! ZV9001
const k = { ["toString"]: () => "k" }; //! ZV9001
const computed = { [`${1}`]: 1 }; //! ZV9001
