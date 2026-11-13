// Math. Results are V8's, which fdlibm computes.
console.log(Math.PI, Math.E, Math.LN2, Math.LN10, Math.LOG2E, Math.LOG10E, Math.SQRT2, Math.SQRT1_2); //> 3.141592653589793 2.718281828459045 0.6931471805599453 2.302585092994046 1.4426950408889634 0.4342944819032518 1.4142135623730951 0.7071067811865476
console.log(Math.abs(-3), Math.abs(-0), Math.floor(-1.5), Math.ceil(1.2), Math.trunc(-4.7), Math.sign(-3), Math.sign(0)); //> 3 0 -2 2 -4 -1 0
console.log(Math.round(2.5), Math.round(-2.5), Math.round(0.49999999999999994), Math.round(-0.4), Math.round(1.5)); //> 3 -2 0 -0 2
console.log(Math.max(1, 5, 3), Math.min(1, 5, 3), Math.max(), Math.min(), Math.max(1, NaN), Math.max(-0, 0), Math.min(0, -0)); //> 5 1 -Infinity Infinity NaN 0 -0
const xs = [4, 9, 2];
console.log(Math.max(...xs), Math.min(...xs, 1)); //> 9 1
console.log(Math.sqrt(16), Math.sqrt(2), Math.cbrt(27), Math.cbrt(-8), Math.hypot(3, 4), Math.hypot(), Math.pow(2, 10), 2 ** 0.5); //> 4 1.4142135623730951 3 -2 5 0 1024 1.4142135623730951
console.log(Math.sin(0), Math.cos(0), Math.sin(Math.PI / 2), Math.cos(Math.PI), Math.tan(0.5), Math.atan2(1, 1), Math.atan(1)); //> 0 1 1 -1 0.5463024898437905 0.7853981633974483 0.7853981633974483
console.log(Math.exp(1), Math.exp(0), Math.log(Math.E), Math.log(1), Math.log2(8), Math.log10(1000), Math.log1p(0), Math.expm1(0)); //> 2.718281828459045 1 1 0 3 3 0 0
console.log(Math.sinh(1), Math.cosh(0), Math.tanh(0), Math.asinh(0), Math.acosh(1), Math.atanh(0), Math.asin(1), Math.acos(1)); //> 1.1752011936438014 1 0 0 0 0 1.5707963267948966 0
console.log(Math.fround(5.5), Math.fround(5.05), Math.imul(3, 4), Math.imul(0xffffffff, 5), Math.clz32(1), Math.clz32(0)); //> 5.5 5.050000190734863 12 -5 31 32
console.log(Math.log(-1), Math.sqrt(-1), Math.pow(-8, 1 / 3), Math.pow(NaN, 0), 1 / Math.round(-0.2)); //> NaN NaN NaN 1 -Infinity
const r = Math.random();
console.log(r >= 0 && r < 1); //> true
