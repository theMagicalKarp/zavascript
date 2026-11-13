// `try`, `catch` and `finally`, and the order they run in.

function attempt(fail: boolean): string {
  const steps: string[] = [];
  try {
    steps.push("try");
    if (fail) {
      throw new Error("failed");
    }
    steps.push("done");
  } catch (e) {
    steps.push("catch");
  } finally {
    steps.push("finally");
  }
  return steps.join(" ");
}
console.log(attempt(false)); //> try done finally
console.log(attempt(true)); //> try catch finally

// A `catch` without a binding.
try {
  throw 1;
} catch {
  console.log("caught"); //> caught
}

// Anything can be thrown.
for (const thrown of [1, "two", null, undefined, { three: 3 }, [4]]) {
  try {
    throw thrown;
  } catch (e) {
    console.log(e); //> 1
    //> two
    //> null
    //> undefined
    //> { three: 3 }
    //> [ 4 ]
  }
}

// A `finally` runs on the way out of a `return`, `break` or `continue`.
function early(): number {
  try {
    return 1;
  } finally {
    console.log("finally after return"); //> finally after return
  }
}
console.log(early()); //> 1

for (let i = 0; i < 3; i++) {
  try {
    if (i === 0) {
      continue;
    }
    if (i === 2) {
      break;
    }
    console.log("body", i);
  } finally {
    console.log("finally", i); //> finally 0
    //> body 1
    //> finally 1
    //> finally 2
  }
}

// What a `finally` does instead wins.
function overridden(): string {
  try {
    throw new Error("lost");
  } finally {
    return "finally wins";
  }
}
console.log(overridden()); //> finally wins

function overriddenReturn(): number {
  try {
    return 1;
  } finally {
    return 2;
  }
}
console.log(overriddenReturn()); //> 2

outer: for (const x of [1, 2]) {
  try {
    throw x;
  } catch (e) {
    continue outer;
  } finally {
    console.log("left", x); //> left 1
    //> left 2
  }
}

// Rethrowing, and throwing from a `catch` or a `finally`.
function rethrow(): void {
  try {
    try {
      throw new Error("inner");
    } catch (e) {
      console.log("inner catch"); //> inner catch
      throw e;
    } finally {
      console.log("inner finally"); //> inner finally
    }
  } catch (e) {
    console.log("outer catch", e instanceof Error ? e.message : e); //> outer catch inner
  }
}
rethrow();

try {
  try {
    throw "first";
  } finally {
    throw "second";
  }
} catch (e) {
  console.log(e); //> second
}

// A `finally` that catches something of its own doesn't lose the exception it's passing on.
try {
  try {
    throw "pending";
  } finally {
    try {
      throw "other";
    } catch (e) {
      console.log("finally caught", e); //> finally caught other
    }
  }
} catch (e) {
  console.log("still", e); //> still pending
}

// Exceptions unwind through calls.
function deep(n: number): number {
  if (n === 0) {
    throw new RangeError("bottom");
  }
  return deep(n - 1) + 1;
}
try {
  deep(5);
} catch (e) {
  console.log(String(e)); //> RangeError: bottom
}

// Through callbacks the builtins call.
try {
  [1, 2, 3].forEach((n) => {
    if (n === 2) {
      throw n;
    }
    console.log("each", n); //> each 1
  });
} catch (e) {
  console.log("stopped at", e); //> stopped at 2
}

// The catch binding is scoped to the clause, and can be destructured.
const e = "outer";
try {
  throw { code: 42, message: "answer" };
} catch ({ code, message }: any) {
  console.log(code, message, e); //> 42 answer outer
}

// Each `catch` gets its own binding, which closures capture.
const handlers: (() => unknown)[] = [];
for (const v of ["a", "b"]) {
  try {
    throw v;
  } catch (caught) {
    handlers.push(() => caught);
  }
}
console.log(handlers.map((h) => h())); //> [ 'a', 'b' ]
