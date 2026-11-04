console.log(1 === 1, "a" === "a", null === null, undefined === undefined); //> true true true true
console.log(null == undefined, null === undefined, null != undefined); //> true false false
console.log(0 / 0 === 0 / 0, 0 === -0); //> false true
console.log(typeof 1 === "number", typeof "s" !== "string"); //> true false
console.log(1 == 1, 1 != 1); //> true false
console.log(1 === null, undefined == 0); //> false false
