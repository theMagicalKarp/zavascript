function f(o: { a?: { b: number } } | undefined, s: string | null) {
  // A `!` inside a chain doesn't remove the `undefined` the chain gives when it stops early,
  // but one at its end does.
  const n: number = o?.a!.b; //! TS2322
  const m: number = o?.a!.b!;
  const k: number = o?.a?.b!;
  const t: string = s!;
  const u: null = s!; //! TS2322
}
