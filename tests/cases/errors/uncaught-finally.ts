// A `finally` runs before an exception carries on out of the program.
try {
  throw new RangeError("out of range"); //!! RangeError: out of range
} finally {
  console.log("cleaned up"); //> cleaned up
}
