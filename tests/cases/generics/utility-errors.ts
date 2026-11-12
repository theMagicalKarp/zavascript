interface Todo {
  title: string;
  done: boolean;
  note?: string;
}
const full: Required<Todo> = { title: "t", done: false }; //! TS2741
const frozen: Readonly<Todo> = { title: "f", done: true };
frozen.title = "g"; //! TS2540
const summary: Pick<Todo, "title"> = { title: "p", done: false }; //! TS2353
type Bad = Pick<Todo, "nope">; //! TS2344
const counts: Record<"a" | "b", number> = { a: 1 }; //! TS2741
const draft: Partial<Todo> = { title: 1 }; //! TS2322
function blanks<T>() {
  const r: Readonly<T> = {}; //! TS2322
  const q: Required<T> = {}; //! TS2322
}
const neither: Partial<Todo | { a: number }> = { c: 1 }; //! TS2353
