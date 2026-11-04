#!/usr/bin/env zavascript
// Comments, and automatic semicolon insertion.
/* block */ console.log(1) /* trailing */ //> 1
console.log(2)
console.log(3); console.log(4)
//> 2
//> 3
//> 4
/*
 * A multi-line comment counts as a line break.
 */ console.log(5) //> 5
console.log(
  6,
  7,
) //> 6 7
console.log(1 +
  2) //> 3
;;; console.log(8) //> 8
