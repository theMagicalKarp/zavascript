// What tsc reports about errors and exceptions.

try {
  throw new Error("x");
} catch (e) {
  e.message; //! TS18046
  const s: string = e; //! TS2322
}

try {
} catch (e: Error) { //! TS1196
}

try {
} catch (e: string | number) { //! TS1196
}

function maybe(text: string): number {
  let n: number;
  try {
    n = JSON.parse(text);
  } catch {
    console.log("failed");
  }
  return n; //! TS2454
}

function noReturn(): number { //! TS2366
  try {
    return 1;
  } catch {
  }
}

function inFinally(): void {
  let n: number;
  try {
    n = 1;
  } finally {
    n; //! TS2454
  }
}

1 instanceof Error; //! TS2358
"s" instanceof Error; //! TS2358
({}) instanceof 5; //! TS2359
({}) instanceof {}; //! TS2359

function narrowed(e: TypeError | string) {
  if (e instanceof Error) {
    e.toUpperCase(); //! TS2339
  } else {
    e.message; //! TS2339
  }
}

new Error(1); //! TS2769
new Error("a", { reason: 1 }); //! TS2353

try {
} catch (e) {
  let e = 1; //! TS2492
}

try {
} catch ([first, second]: any) {
  const second = 2; //! ZV9001
  {
    const first = 1;
  }
}

// A property assigned in the `try` block may hold either type in the `catch`.
const holder: { x: string | number } = { x: "a" };
holder.x = "a";
try {
  holder.x = 1;
  JSON.parse("{");
} catch {
  const s: string = holder.x; //! TS2322
}
