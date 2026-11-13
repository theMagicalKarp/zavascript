// It's reported from where it was last thrown.
function fail(): never {
  throw new Error("first");
}
try {
  fail();
} catch (e) {
  console.log("logged"); //> logged
  throw e; //!! Error: first
}
