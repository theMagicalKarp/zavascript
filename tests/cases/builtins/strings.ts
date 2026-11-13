// String.prototype. Indices and lengths count UTF-16 code units, as in JavaScript.
const s = "Hello, World";
console.log(s.length, s[0], s[100], s.charAt(4), s.charAt(-1), s.charCodeAt(1), s.codePointAt(0), s.at(-1)); //> 12 H undefined o  101 72 d
console.log(s.slice(7), s.slice(-5, -1), s.substring(5, 0), s.substring(7), s.substr(-5, 3), s.substr(1, 2)); //> World Worl Hello World Wor el
console.log(s.toUpperCase(), s.toLowerCase(), "Grüße, 世界".toLowerCase(), "Grüße, ÿ".toUpperCase(), "ÀÉÎ".toLowerCase()); //> HELLO, WORLD hello, world grüße, 世界 GRÜSSE, Ÿ àéî
console.log(s.indexOf("o"), s.indexOf("o", 5), s.lastIndexOf("o"), s.lastIndexOf("o", 5), s.indexOf("z"), s.indexOf("")); //> 4 8 8 4 -1 0
console.log(s.includes("World"), s.startsWith("Hell"), s.startsWith("World", 7), s.endsWith("d"), s.endsWith("Hello", 5)); //> true true true true true
console.log(`[${"  x ".trim()}]`, `[${"  x ".trimStart()}]`, `[${"  x ".trimEnd()}]`, `[${"\t\n x ".trim()}]`); //> [x] [x ] [  x] [x]
console.log("5".padStart(3, "0"), "ab".padEnd(5, "xy"), "abc".padStart(2), "x".padStart(4), "ab".repeat(3), "".repeat(5)); //> 005 abxyx abc    x ababab 
console.log("a,b,,c".split(","), "abc".split(""), "a-b-c".split("-", 2), "x".split(","), "".split(","), "".split("")); //> [ 'a', 'b', '', 'c' ] [ 'a', 'b', 'c' ] [ 'a', 'b' ] [ 'x' ] [ '' ] []
console.log("aXbXc".replace("X", "_"), "aXbXc".replaceAll("X", "_"), "abc".replace("b", (m) => m.toUpperCase())); //> a_bXc a_b_c aBc
console.log("abc".replace("b", "[$&|$`|$'|$$]"), "aaa".replaceAll("", "-"), "abc".replace("z", "y")); //> a[b|a|c|$]c -a-a-a- abc
console.log("a".concat("b", "c"), "x".toString(), "y".valueOf(), String(12), String(null), String(), String([1, 2])); //> abc x y 12 null  1,2
console.log(String.fromCharCode(72, 105), String.fromCodePoint(128512, 65)); //> Hi 😀A
// Outside the Basic Multilingual Plane, a code point is two code units.
const emoji = "a😀b";
console.log(emoji.length, emoji.charCodeAt(1), emoji.codePointAt(1), emoji.codePointAt(2), emoji.slice(1, 3), emoji.indexOf("b")); //> 4 55357 128512 56832 😀 3
console.log([...emoji], emoji.split(""), emoji.slice(1, 2) + emoji.slice(2, 3) === "😀"); //> [ 'a', '😀', 'b' ] [ 'a', '\ud83d', '\ude00', 'b' ] true
for (const ch of "héllo") {
  console.log(ch);
//> h
//> é
//> l
//> l
//> o
}
const letters: string[] = [..."abc"];
console.log(letters.map((c) => c.charCodeAt(0))); //> [ 97, 98, 99 ]
console.log("Ÿ".toUpperCase(), "Ÿ".toLowerCase(), "µ".toUpperCase(), "µ".toUpperCase().toLowerCase()); //> Ÿ ÿ Μ μ
// Long strings of the same length, walked together, mustn't be mistaken for each other.
const first = "àé".repeat(200) + "x";
const second = "îõ".repeat(200) + "y";
const third = "ab".repeat(200) + "z";
let walked = "";
for (let i = 0; i < first.length; i += 100) {
  walked += first[i] + second.charAt(i) + third[i] + first.length + second.length + third.length + "|";
}
console.log(walked, first.indexOf("x"), second.lastIndexOf("õî"), (first + second).slice(399, 402)); //> àîa401401401|àîa401401401|àîa401401401|àîa401401401|xyz401401401| 400 397 éxî
