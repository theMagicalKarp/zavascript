// Generic code that would need types we don't have yet.
function f<T>(x: T) {
  if (typeof x === "string") { //! ZV9001
  }
}
type E = Exclude<1 | 2, 1>; //! ZV9001
type K = keyof number[]; //! ZV9001
type O = Omit<{ a: 1 }, "a">; //! ZV9001
type Tree<T> = Node<T>; //! ZV9001
type Node<T> = { value: T; children: Tree<T>[] };
