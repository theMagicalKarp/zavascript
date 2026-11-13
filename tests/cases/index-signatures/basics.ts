// Index signatures, which Record<string, T> is too.
const scores: { [name: string]: number } = { alice: 1 };
scores.bob = 2;
scores["carol"] = 3;
console.log(scores, scores.alice, scores["bob"], scores.nobody); //> { alice: 1, bob: 2, carol: 3 } 1 2 undefined
const byLength: Record<string, string[]> = {};
for (const word of ["a", "bb", "cc"]) {
  const key = String(word.length);
  byLength[key] = [...(byLength[key] ?? []), word];
}
console.log(byLength); //> { '1': [ 'a' ], '2': [ 'bb', 'cc' ] }
const byNumber: { [n: number]: string } = { 1: "one", 2: "two" };
console.log(byNumber[1], byNumber[3]); //> one undefined
interface Dictionary<T> {
  [key: string]: T;
}
const d: Dictionary<boolean> = { yes: true };
console.log(d.yes, Object.keys(d)); //> true [ 'yes' ]
const readonlyScores: { readonly [name: string]: number } = { a: 1 };
console.log(readonlyScores.a); //> 1
// An object literal's type has an implicit index signature; an interface's doesn't.
const literal = { a: 1, b: 2 };
const asIndex: { [k: string]: number } = literal;
console.log(asIndex, Object.values(literal).map((n) => n * 2)); //> { a: 1, b: 2 } [ 2, 4 ]
