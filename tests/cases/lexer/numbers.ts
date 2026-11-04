// Numeric literals in every radix, and Number::toString for the tricky values.
console.log(0x10, 0X1f, 0o17, 0b1010, 1_000_000); //> 16 31 15 10 1000000
console.log(.5, 5., 1e3, 2.5E-3, 1e+2); //> 0.5 5 1000 0.0025 100
console.log(0.1 + 0.2); //> 0.30000000000000004
console.log(1 / 3, 100 / 3); //> 0.3333333333333333 33.333333333333336
console.log(1e21, 1e20, 123e18); //> 1e+21 100000000000000000000 123000000000000000000
console.log(1e-7, 1.5e-7, 0.000001); //> 1e-7 1.5e-7 0.000001
console.log(2 ** 53, 2 ** 53 + 1); //> 9007199254740992 9007199254740992
console.log(5e-324, 1.7976931348623157e308); //> 5e-324 1.7976931348623157e+308
console.log(1.7976931348623157e308 * 10, -1 / 0, 0 / 0); //> Infinity -Infinity NaN
console.log(-0, `${-0}`, 0 * -1); //> -0 0 -0
console.log(0x20000000000001, 0xFFFFFFFFFFFFFFFFFF); //> 9007199254740992 4.722366482869645e+21
