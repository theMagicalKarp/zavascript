// What the checker knows in `catch` and `finally` blocks.

function parse(text: string): number | undefined {
  let result: number | undefined;
  try {
    result = JSON.parse(text);
  } catch (e) {
    // It could have thrown before the assignment.
    if (e instanceof SyntaxError) {
      console.log("bad", text, result); //> bad { undefined
    }
  }
  return result;
}
console.log(parse("1"), parse("{")); //> 1 undefined

// Assignments in the `try` block are seen in the `catch`.
let state: "start" | "middle" | "end" = "start";
try {
  state = "middle";
  JSON.parse("x");
  state = "end";
} catch {
  const s: "start" | "middle" | "end" = state;
  console.log(s); //> middle
}

// After a `try` that always returns or throws, nothing runs.
function always(flag: boolean): number {
  try {
    if (flag) {
      return 1;
    }
    throw new Error("no");
  } catch {
    return 2;
  }
}
console.log(always(true), always(false)); //> 1 2

// Assigned in both the `try` and the `catch`, a variable is definitely assigned after.
function assigned(text: string): number {
  let n: number;
  try {
    n = JSON.parse(text);
  } catch {
    n = -1;
  }
  return n;
}
console.log(assigned("5"), assigned("?")); //> 5 -1

// And in a `finally`, whatever happens.
function cleanup(): string {
  let s: string;
  try {
    JSON.parse("?");
  } finally {
    s = "set";
  }
  return s;
}
try {
  cleanup();
} catch (e) {
  console.log(e instanceof SyntaxError); //> true
}

// `unknown` narrows by `typeof` too.
try {
  throw "text";
} catch (e) {
  if (typeof e === "string") {
    console.log(e.toUpperCase()); //> TEXT
  }
}

// `any` if it's annotated so.
try {
  throw { anything: true };
} catch (e: any) {
  console.log(e.anything); //> true
}

// A function that only throws returns `never`.
function fail(message: string): never {
  throw new Error(message);
}
function checked(n: number): number {
  if (n < 0) {
    fail("negative");
  }
  return n;
}
try {
  checked(-1);
} catch (e) {
  console.log((e as Error).message); //> negative
}
