interface Point {
  x: number;
  y: number;
  label?: string;
}
const k: keyof Point = "label";
const keys: (keyof Point)[] = ["x", "y"];
console.log(k, keys); //> label [ 'x', 'y' ]

// Indexed access types.
type X = Point["x"];
type Label = Point["label"];
type Coordinate = Point["x" | "y"];
const x: X = 1;
const label: Label = undefined;
const c: Coordinate = 2;
console.log(x, label, c); //> 1 undefined 2
type Element = string[][number];
type Second = [boolean, string][1];
const e: Element = "e";
const second: Second = "s";
console.log(e, second); //> e s

// `K extends keyof T` and `T[K]`.
function get<T, K extends keyof T>(o: T, key: K): T[K] {
  return o[key];
}
const point: Point = { x: 1, y: 2 };
const gx: number = get(point, "x");
const gl: string | undefined = get(point, "label");
console.log(gx, gl); //> 1 undefined
function set<T, K extends keyof T>(o: T, key: K, value: T[K]): void {
  o[key] = value;
}
set(point, "y", 5);
console.log(point.y); //> 5

// `typeof` in a type.
const config = { debug: true, level: 3 };
type Config = typeof config;
const other: Config = { debug: false, level: 1 };
const level: typeof config.level = 4;
function double(n: number): number {
  return n * 2;
}
const d2: typeof double = (n) => n + n;
type ConfigKey = keyof typeof config;
const key: ConfigKey = "level";
console.log(other, level, d2(3), key); //> { debug: false, level: 1 } 4 6 level
