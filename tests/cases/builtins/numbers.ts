// Number, Number.prototype, and the global number functions.
console.log(Number("12"), Number(""), Number(" 42 "), Number("x"), Number("0x1f"), Number(true), Number(null), Number(), Number([5])); //> 12 0 42 NaN 31 1 0 0 5
console.log(Number.isInteger(5), Number.isInteger(5.5), Number.isSafeInteger(2 ** 53), Number.isNaN(NaN), Number.isNaN("x"), Number.isFinite(1 / 0)); //> true false false true false false
console.log(isNaN(Number("x")), isFinite(1), Number.parseInt === parseInt, Number.parseFloat === parseFloat); //> true true true true
console.log(Number.MAX_SAFE_INTEGER, Number.MIN_SAFE_INTEGER, Number.EPSILON, Number.MAX_VALUE, Number.MIN_VALUE, Number.NaN); //> 9007199254740991 -9007199254740991 2.220446049250313e-16 1.7976931348623157e+308 5e-324 NaN
console.log(Number.POSITIVE_INFINITY, Number.NEGATIVE_INFINITY, NaN, Infinity); //> Infinity -Infinity NaN Infinity
console.log(parseInt("42px"), parseInt("0x1f"), parseInt("101", 2), parseInt("z", 36), parseInt("  -7"), parseInt(""), parseInt("12", 1)); //> 42 31 5 35 -7 NaN NaN
console.log(parseFloat("3.14abc"), parseFloat(".5"), parseFloat("-0"), parseFloat("1e3x"), parseFloat("Infinityx"), parseFloat("x")); //> 3.14 0.5 -0 1000 Infinity NaN
console.log((1.005).toFixed(2), (1234.5678).toFixed(1), (0.000001).toFixed(7), (-1.5).toFixed(0), (2.5).toFixed(0), (1e21).toFixed(2), (0).toFixed(2)); //> 1.00 1234.6 0.0000010 -2 3 1e+21 0.00
console.log((255).toString(16), (255).toString(2), (0.5).toString(2), (3.14159).toString(8), (-255).toString(36), (0.1).toString(3)); //> ff 11111111 0.1 3.11037476006703156 -73 0.0022002200220022002200220022002201
console.log((123.456).toPrecision(4), (0.00001234).toPrecision(2), (123456).toPrecision(2), (1.5).toPrecision(1), (0).toPrecision(3)); //> 123.5 0.000012 1.2e+5 2 0.00
console.log((1.5).toExponential(3), (12345).toExponential(), (0).toExponential(2), (-0.00015).toExponential(1), (1e21).toExponential()); //> 1.500e+0 1.2345e+4 0.00e+0 -1.5e-4 1e+21
console.log((5).valueOf(), (1e21).toString(), (1 / 3).toString(), Boolean(0), Boolean("x"), Boolean(), true.toString(), false.valueOf()); //> 5 1e+21 0.3333333333333333 false true false true false
