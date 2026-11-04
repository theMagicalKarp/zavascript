// Straight-line expressions: mostly measures lexing, parsing and checking until the language has
// loops. Replace with heavier cases as features land.
console.log(1 + 2 * 3 - 4 / 5 % 6 ** 2, (1 + 2) * (3 - 4) / (5 + 6));
console.log("a" + "b" + 1 + 2 + `c${3 + 4}d${"e" + "f"}g`, typeof 1 + typeof "s");
console.log(0x7fffffff | 0, 1 << 30 >>> 1, ~123 & 0xff ^ 0x0f, -2147483648 >> 3);
console.log(1 < 2 && 2 < 3 || 3 < 4, "abc" < "abd", 1 <= 1 && 2 >= 2, 0.1 + 0.2 === 0.3);
console.log((1 < 2) ? "yes" : "no", (2 < 1) ? 1 : (3 < 4) ? 2 : 3, NaN ?? 0, console.log() ?? "d");
console.log(1e21, 1e-7, 123.456, -0, 5e-324, 1.7976931348623157e308, 2 ** 53 + 1);
console.log(`template ${1} with ${"several"} ${true} substitutions ${null} and ${undefined}`);
console.log(((((((((1 + 2) * 3) - 4) / 5) % 6) ** 2) + 7) * 8) - 9);
