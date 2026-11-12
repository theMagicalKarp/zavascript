interface Node { value: number; next?: Node }
const list: Node = { value: 1, next: { value: 2 } };
console.log(list.next!.value); //> 2
function first(xs: number[] | undefined) {
  return xs![0];
}
console.log(first([3])); //> 3
let maybe: string | null = "s";
const sure: string = maybe!;
console.log(sure); //> s
// A non-null assertion doesn't check anything at runtime.
const missing: Node | undefined = undefined;
console.log(missing!); //> undefined
console.log(list.next?.next!); //> undefined
