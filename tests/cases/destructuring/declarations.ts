interface Config {
  host: string;
  port?: number;
  tags: string[];
}
const config: Config = { host: "localhost", tags: ["a", "b"] };
const { host, port = 80, tags: [first, ...others] } = config;
console.log(host, port, first, others); //> localhost 80 a [ 'b' ]
const { host: h, ...rest } = config;
console.log(h, rest); //> localhost { tags: [ 'a', 'b' ] }
const [a, , c = 3, d = 4] = [1, 2, undefined, 0];
console.log(a, c, d); //> 1 3 0
let [x, y] = [1, "two"];
x += 1;
y += "!";
console.log(x, y); //> 2 two!
const [[p, q], { r }] = [[1, 2], { r: 3 }];
console.log(p + q + r); //> 6
const [...all] = [1, 2];
const { length } = all;
console.log(all, length); //> [ 1, 2 ] 2
const { 0: zero } = ["z"];
console.log(zero); //> z
// Defaults are evaluated only when they're needed.
let calls = 0;
const next = () => ++calls;
const [e = next(), f = next()] = [10];
console.log(e, f, calls); //> 10 1 1
// Names are given to anonymous functions.
const { fn = () => 0 } = {};
const [g = function () {}] = [];
console.log(fn.name, g.name); //> fn g
