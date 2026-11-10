const p = { x: 1, y: 2 };
p.x = 10;
p["y"] += 5;
p.x++;
++p["x"];
console.log(p); //> { x: 12, y: 7 }
const k = "x";
console.log(p[k], p["y"]); //> 12 7

interface Options {
  name: string;
  verbose?: boolean;
}
const opts: Options = { name: "a", verbose: true };
console.log("verbose" in opts, "other" in opts, "name" in opts); //> true false true
delete opts.verbose;
console.log(opts, "verbose" in opts, opts.verbose); //> { name: 'a' } false undefined
opts.verbose = false;
console.log(opts); //> { name: 'a', verbose: false }
opts.verbose ??= true;
console.log(opts.verbose); //> false

const counts = { a: 0 };
counts.a ||= 5;
counts.a &&= counts.a * 2;
console.log(counts.a); //> 10
console.log("length" in [1], 0 in [1], 1 in [1]); //> true true false

// Objects are shared, not copied.
const alias = p;
alias.x = 0;
console.log(p.x); //> 0
