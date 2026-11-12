interface Config {
  name?: string;
  nested?: { level?: number };
}
function f(c: Config) {
  if (c.name) {
    const n: number = c.name; //! TS2322
  }
  c.name + 1; //! TS18048
  if (c.nested) {
    // Assigning the object forgets what was known about its properties.
    c.nested.level = 1;
    const n: number = c.nested.level;
    c.nested = { level: undefined };
    c.nested.level + 1; //! TS18048
  }
  if (c.nested?.level) {
    c.nested.level + 1;
    c = {};
    c.nested.level; //! TS18048
  }
}
function viaConstKey(o: { a: string | null }) {
  const k = "a";
  if (o.a !== null) {
    o[k] = null;
    const s: string = o.a; //! TS2322
  }
  if (o[k] !== null) {
    const s: string = o.a;
  }
}
