// console.log's format specifiers, console.group's indentation and console.count.
console.log("%s is %d years old", "Bob", 42, "and more", { a: 1 }); //> Bob is 42 years old and more { a: 1 }
console.log("%i %f %j %O %%", 42.9, "3.5x", { a: [1] }, { b: { c: { d: {} } } }); //> 42 3.5 {"a":[1]} { b: { c: { d: {} } } } %
console.log("%s", [1, [2, [3]]], "%s"); //> [ 1, [Array] ] %s
console.log("%s %s %s", -0, { x: 1 }, null); //> -0 { x: 1 } null
console.log("%d", "abc", "%c", "x"); //> NaN %c x
console.log("100%", 5, "%"); //> 100% 5 %
console.log("%s"); //> %s
console.log("%c styled", "color: red"); //>  styled
console.group("Group"); //> Group
console.log("inside\nover two lines");
//>   inside
//>   over two lines
console.group();
console.info({ a: 1 }); //>     { a: 1 }
console.groupEnd();
console.groupCollapsed("collapsed", 1); //>   collapsed 1
console.debug("deeper"); //>     deeper
console.groupEnd();
console.groupEnd();
console.groupEnd();
console.log("outside"); //> outside
console.count(); //> default: 1
console.count(); //> default: 2
console.count("x"); //> x: 1
console.countReset();
console.count(); //> default: 1
console.countReset("missing");
console.dir("a string"); //> 'a string'
console.dir({ a: { b: { c: { d: 1 } } } }); //> { a: { b: { c: [Object] } } }
console.assert(true, "not shown");
console.log(console.log === console.log, typeof console.log); //> true function
