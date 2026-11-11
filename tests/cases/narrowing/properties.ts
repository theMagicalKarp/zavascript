// Properties narrow like variables do.
interface Config {
  name?: string;
  retries: number | null;
  nested?: { level?: number };
}
function describe(c: Config) {
  let out = "";
  if (c.name) {
    out += c.name + " ";
  }
  if (c.retries !== null) {
    out += c.retries + 1;
  }
  if (c.nested && c.nested.level !== undefined) {
    out += " level " + (c.nested.level * 10);
  }
  if (typeof c.nested?.level === "number") {
    out += " again " + c.nested.level;
  }
  return out;
}
console.log(describe({ name: "a", retries: 1, nested: { level: 2 } })); //> a 2 level 20 again 2
console.log(describe({ retries: null })); //>
// An assignment to a property narrows it to what was assigned.
function assign(c: Config) {
  c.retries = 3;
  const n: number = c.retries;
  c.nested = {};
  return n + (c.nested.level ?? 0);
}
console.log(assign({ retries: null })); //> 3
// Indexing with a literal is the same property.
function indexed(c: Config) {
  if (c["name"] !== undefined) {
    return c.name + "!";
  }
  return "none";
}
console.log(indexed({ name: "n", retries: 0 }), indexed({ retries: 0 })); //> n! none
