const point = { x: 1, y: 2 };
console.log(point); //> { x: 1, y: 2 }
console.log(point.x + point.y); //> 3
const x = 10;
console.log({ x, label: "p" }); //> { x: 10, label: 'p' }
const key = "dyn";
console.log({ [key]: 1, [2]: "two" }); //> { '2': 'two', dyn: 1 }
console.log({ ...point, z: 3, x: 5 }); //> { x: 5, y: 2, z: 3 }
console.log({ "a-b": 1, 2: 2, c: 3, 1: 1, _ok: 0 }); //> { '1': 1, '2': 2, 'a-b': 1, c: 3, _ok: 0 }
console.log({}); //> {}
console.log({ "it's": "it's" }); //> { "it's": "it's" }
const methods = {
  m(a: number) {
    return a + 1;
  },
  f: () => 2,
  g: function () {},
  [key]: () => 3,
};
console.log(methods.m(1), methods.f(), methods.dyn()); //> 2 2 3
console.log(methods); //> {
//>   m: [Function: m],
//>   f: [Function: f],
//>   g: [Function: g],
//>   dyn: [Function: dyn]
//> }
console.log(`${methods.m}`); //> m(a        ) {
//>     return a + 1;
//>   }
console.log(typeof point, `${point}`); //> object [object Object]
const copy = { ...point };
console.log(point === point, point === copy, copy); //> true false { x: 1, y: 2 }
