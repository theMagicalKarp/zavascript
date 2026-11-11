// `as` changes the type the checker sees, and does nothing at runtime.
const u: unknown = "text";
const s = u as string;
console.log(s + "!"); //> text!
const n = (1 as number) + 1;
console.log(n); //> 2
const wide = "a" as string | number;
console.log(wide); //> a
function letter(l: string) {
  return (l as "x" | "y") === "x";
}
console.log(letter("x")); //> true
// `as const` keeps literal types, and makes object literals' properties `readonly`.
let c = "const" as const;
const point = { x: 1, y: "two" } as const;
const x: 1 = point.x;
const y: "two" = point.y;
console.log(c, x, y, point); //> const 1 two { x: 1, y: 'two' }
// `satisfies` checks a type without changing it.
const config = { port: 80, host: "localhost" } satisfies { port: number; host: string };
let port = config.port;
port = 8080;
console.log(port, config.host); //> 8080 localhost
const literal = "a" satisfies "a" | "b";
console.log(literal); //> a
