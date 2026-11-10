interface Base {
  id: number;
}
interface Derived extends Base {
  name: string;
  greet(greeting: string): string;
}
const d: Derived = {
  id: 1,
  name: "d",
  greet(greeting: string) {
    return `${greeting}, ${this_name()}`;
  },
};
function this_name() {
  return d.name;
}
console.log(d.greet("hi"), d.id); //> hi, d 1
interface Node {
  value: number;
  next?: Node;
}
const list: Node = { value: 1, next: { value: 2, next: { value: 3 } } };
type Alias = Derived;
const aliased: Alias = d;
console.log(aliased.name); //> d
type Coord = [number, number];
type Grid = Coord[];
const grid: Grid = [
  [0, 0],
  [1, 2],
];
console.log(grid[1][1]); //> 2
{
  // Types are block scoped.
  interface Local {
    inner: boolean;
  }
  const l: Local = { inner: true };
  console.log(l); //> { inner: true }
}
const usedBefore: Later = { later: 1 };
interface Later {
  later: number;
}
console.log(usedBefore, list.next); //> { later: 1 } { value: 2, next: { value: 3 } }
