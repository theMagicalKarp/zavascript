function count(...items: number[]) {
  return items.length;
}
console.log(count(), count(1, 2, 3)); //> 0 3
function list(first: string, ...rest: string[]) {
  return rest;
}
console.log(list("a"), list("a", "b", "c")); //> [] [ 'b', 'c' ]
function numbers(...n: number[]) {
  return n;
}
console.log(numbers(1, 2, 3, 4, 5, 6)); //> [ 1, 2, 3, 4, 5, 6 ]
console.log(numbers(1, 2, 3, 4, 5, 6, 7));
//> [
//>   1, 2, 3, 4,
//>   5, 6, 7
//> ]
console.log(numbers(1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27));
//> [
//>    1,  2,  3,  4,  5,  6,  7,  8,
//>    9, 10, 11, 12, 13, 14, 15, 16,
//>   17, 18, 19, 20, 21, 22, 23, 24,
//>   25, 26, 27
//> ]
console.log(numbers(100000, 2, 3333, 4, 5, 6, 7777777, 8, 9)); //> [ 100000, 2, 3333, 4, 5, 6, 7777777, 8, 9 ]
function strings(...s: string[]) {
  return s;
}
console.log(strings("a", "bb", "ccc", "dddd", "e", "f", "g", "h"));
//> [
//>   'a',   'bb',
//>   'ccc', 'dddd',
//>   'e',   'f',
//>   'g',   'h'
//> ]
console.log("" + numbers(1, 2), `${numbers()}`, +numbers(5), +numbers(), +numbers(1, 2)); //> 1,2  5 0 NaN
