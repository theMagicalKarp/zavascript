// String literals and their escapes.
console.log('single', "double"); //> single double
console.log('it\'s', "say \"hi\"", 'mixed "quotes"'); //> it's say "hi" mixed "quotes"
console.log("\x41B\u{43}\u{1F600}"); //> ABC😀
console.log("\u{1F600}" === "😀"); //> true
console.log("back\\slash", "\q"); //> back\slash q
console.log("line \
continued"); //> line continued
console.log("café ☕"); //> café ☕
console.log("a\nb");
//> a
//> b
