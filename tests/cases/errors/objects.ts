// `Error` and its subclasses.

const e = new Error("boom");
console.log(e.name, e.message); //> Error boom
console.log(String(e), `${e}`, e.toString(), "" + e); //> Error: boom Error: boom Error: boom Error: boom
console.log(typeof e, typeof e.stack); //> object string
console.log(e.stack?.split("\n")[0]); //> Error: boom

// Calling one without `new` makes one too.
const called = TypeError("called");
console.log(called instanceof TypeError, called.name); //> true TypeError

// Without a message, it's the prototype's empty one.
console.log(JSON.stringify(new Error().message), String(new RangeError())); //> "" RangeError
console.log(Object.hasOwn(new Error(), "message"), Object.hasOwn(new Error("x"), "message")); //> false true

// Each subclass.
const constructors: ErrorConstructor[] = [Error, EvalError, RangeError, ReferenceError, SyntaxError, TypeError, URIError];
for (const C of constructors) {
  const err = new C("m");
  console.log(err.name, err instanceof Error, err instanceof C, String(err)); //> Error true true Error: m
  //> EvalError true true EvalError: m
  //> RangeError true true RangeError: m
  //> ReferenceError true true ReferenceError: m
  //> SyntaxError true true SyntaxError: m
  //> TypeError true true TypeError: m
  //> URIError true true URIError: m
}
console.log(new TypeError("t") instanceof RangeError, new Error("e") instanceof TypeError); //> false false
console.log(String(TypeError)); //> function TypeError() { [native code] }

// Their own properties aren't enumerable, so they don't show up as keys or in JSON.
interface Coded extends Error {
  code?: number;
}
const coded: Coded = new Error("with code");
coded.code = 7;
console.log(Object.keys(coded), JSON.stringify(coded), "message" in coded, "name" in coded); //> [ 'code' ] {"code":7} true true
const copy = { ...new Error("spread") };
console.log(copy); //> {}

// A cause.
const caused = new Error("outer", { cause: new Error("inner") });
console.log(caused.cause instanceof Error ? caused.cause.message : "none"); //> inner
console.log(new Error("x", {}).cause, "cause" in new Error("x", {}), "cause" in new Error("x", { cause: undefined })); //> undefined false true

// Assigning `name` and `message`.
const renamed = new Error("old");
renamed.name = "Custom";
renamed.message = "new";
console.log(String(renamed), Object.keys(renamed)); //> Custom: new [ 'name' ]
renamed.name = "";
console.log(String(renamed)); //> new
const unnamed = new Error();
unnamed.name = "OnlyName";
console.log(String(unnamed)); //> OnlyName
const deleted = new Error("gone");
delete (deleted as { message?: string }).message;
console.log(JSON.stringify(deleted.message), Object.hasOwn(deleted, "message")); //> "" false

// The message is converted to a string.
console.log(new Error(42 as any).message, typeof new Error(42 as any).message); //> 42 string
console.log(new Error(undefined).message === ""); //> true

// `console.log` shows an error by its stack, without frames here since they differ from node's;
// so only errors without a stack are shown.
const bare = new Error("bare");
bare.stack = undefined;
console.log(bare); //> [Error: bare]
console.log({ bare }); //> { bare: [Error: bare] }
interface Extra extends TypeError {
  extra?: string;
}
const props: Extra = new TypeError("props");
props.stack = "";
props.extra = "x";
console.log(props); //> [TypeError: props] { extra: 'x' }

// An error whose message is itself can't be made a string, as V8 runs out of stack.
const looped: any = new Error("m");
looped.message = looped;
try {
  String(looped);
} catch (x) {
  console.log(String(x)); //> RangeError: Maximum call stack size exceeded
}

// Its stack can be deleted, and assigning it then makes an own, enumerable one.
const unstacked: any = new Error("s");
delete unstacked.stack;
console.log("stack" in unstacked, Object.hasOwn(unstacked, "stack"), unstacked.stack); //> false false undefined
unstacked.stack = "x";
console.log(Object.keys(unstacked), unstacked.stack); //> [ 'stack' ] x
