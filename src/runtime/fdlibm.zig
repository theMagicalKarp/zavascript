//! The math functions as V8 computes them, which is with fdlibm: node prints `Math.cos(0.1)` as
//! 0.9950041652780257, not the correctly rounded ...258 that the platform's libm may give. These
//! are ports of the same algorithms, so the results are the same everywhere. The ones Zig's
//! `std.math` has from musl that are still fdlibm's (atan, asin, acos, atan2, cbrt, expm1, log1p)
//! come from there, and so does the reduction of huge arguments for the trigonometric functions.
//!
//! A node built for arm64 can differ in the last bit, since its compiler fuses multiplies and adds
//! there; these match node on x86-64.
//!
//! fdlibm is Copyright (C) 1993 by Sun Microsystems, Inc.: "Developed at SunSoft, a Sun
//! Microsystems, Inc. business. Permission to use, copy, modify, and distribute this software is
//! freely granted, provided that this notice is preserved."

const std = @import("std");
const rem_pio2_large = @import("fdlibm/rem_pio2_large.zig").rem_pio2_large;

pub const atan = std.math.atan;
pub const asin = std.math.asin;
pub const acos = std.math.acos;
pub const atan2 = std.math.atan2;
pub const cbrt = std.math.cbrt;
pub const expm1 = std.math.expm1;
pub const log1p = std.math.log1p;

fn high(x: f64) i32 {
    return @bitCast(@as(u32, @truncate(@as(u64, @bitCast(x)) >> 32)));
}

fn low(x: f64) u32 {
    return @truncate(@as(u64, @bitCast(x)));
}

fn fromWords(hi: i32, lo: u32) f64 {
    return @bitCast((@as(u64, @as(u32, @bitCast(hi))) << 32) | lo);
}

fn withLow(x: f64, lo: u32) f64 {
    return fromWords(high(x), lo);
}

fn withHigh(x: f64, hi: i32) f64 {
    return fromWords(hi, low(x));
}

// Trigonometry.

/// k_sin.c: sin(x + y) for |x| <= pi/4, `y` the tail of `x` when `iy` is 1.
fn kernelSin(x: f64, y: f64, iy: i32) f64 {
    const S1 = -1.66666666666666324348e-01; // 0xBFC55555, 0x55555549
    const S2 = 8.33333333332248946124e-03; // 0x3F811111, 0x1110F8A6
    const S3 = -1.98412698298579493134e-04; // 0xBF2A01A0, 0x19C161D5
    const S4 = 2.75573137070700676789e-06; // 0x3EC71DE3, 0x57B1FE7D
    const S5 = -2.50507602534068634195e-08; // 0xBE5AE5E6, 0x8A2B9CEB
    const S6 = 1.58969099521155010221e-10; // 0x3DE5D93A, 0x5ACFD57C
    const ix = high(x) & 0x7fffffff;
    if (ix < 0x3e400000) { // |x| < 2**-27
        return x;
    }
    const z = x * x;
    const v = z * x;
    const r = S2 + z * (S3 + z * (S4 + z * (S5 + z * S6)));
    if (iy == 0) {
        return x + v * (S1 + z * r);
    }
    return x - ((z * (0.5 * y - v * r) - y) - v * S1);
}

/// k_cos.c: cos(x + y) for |x| <= pi/4.
fn kernelCos(x: f64, y: f64) f64 {
    const C1 = 4.16666666666666019037e-02; // 0x3FA55555, 0x5555554C
    const C2 = -1.38888888888741095749e-03; // 0xBF56C16C, 0x16C15177
    const C3 = 2.48015872894767294178e-05; // 0x3EFA01A0, 0x19CB1590
    const C4 = -2.75573143513906633035e-07; // 0xBE927E4F, 0x809C52AD
    const C5 = 2.08757232129817482790e-09; // 0x3E21EE9E, 0xBDB4B1C4
    const C6 = -1.13596475577881948265e-11; // 0xBDA8FAE9, 0xBE8838D4
    const ix = high(x) & 0x7fffffff;
    if (ix < 0x3e400000) { // |x| < 2**-27
        return 1.0;
    }
    const z = x * x;
    const r = z * (C1 + z * (C2 + z * (C3 + z * (C4 + z * (C5 + z * C6)))));
    if (ix < 0x3FD33333) { // |x| < 0.3
        return 1.0 - (0.5 * z - (z * r - x * y));
    }
    const qx = if (ix > 0x3fe90000) 0.28125 else fromWords(ix - 0x00200000, 0); // x/4
    const hz = 0.5 * z - qx;
    const a = 1.0 - qx;
    return a - (hz - (z * r - x * y));
}

/// k_tan.c: tan(x + y) for |x| <= pi/4 when `iy` is 1, -1/tan(x + y) when it's -1.
fn kernelTan(x_: f64, y_: f64, iy: i32) f64 {
    const T = [_]f64{
        3.33333333333334091986e-01, // 3FD55555, 55555563
        1.33333333333201242699e-01, // 3FC11111, 1110FE7A
        5.39682539762260521377e-02, // 3FABA1BA, 1BB341FE
        2.18694882948595424599e-02, // 3F9664F4, 8406D637
        8.86323982359930005737e-03, // 3F8226E3, E96E8493
        3.59207910759131235356e-03, // 3F6D6D22, C9560328
        1.45620945432529025516e-03, // 3F57DBC8, FEE08315
        5.88041240820264096874e-04, // 3F4344D8, F2F26501
        2.46463134818469906812e-04, // 3F3026F7, 1A8D1068
        7.81794442939557092300e-05, // 3F147E88, A03792A6
        7.14072491382608190305e-05, // 3F12B80F, 32F0A7E9
        -1.85586374855275456654e-05, // BEF375CB, DB605373
        2.59073051863633712884e-05, // 3EFB2A70, 74BF7AD4
    };
    const pio4 = 7.85398163397448278999e-01; // 3FE921FB, 54442D18
    const pio4lo = 3.06161699786838301793e-17; // 3C81A626, 33145C07
    var x = x_;
    var y = y_;
    const hx = high(x);
    const ix = hx & 0x7fffffff;
    if (ix < 0x3e300000) { // |x| < 2**-28
        if (((ix | @as(i32, @bitCast(low(x)))) | (iy + 1)) == 0) {
            return 1.0 / @abs(x);
        }
        if (iy == 1) {
            return x;
        }
        // Compute -1 / (x+y) carefully.
        const w = x + y;
        const z = withLow(w, 0);
        const v = y - (z - x);
        const a = -1.0 / w;
        const t = withLow(a, 0);
        const s = 1.0 + t * z;
        return t + a * (s + t * v);
    }
    if (ix >= 0x3FE59428) { // |x| >= 0.6744
        if (hx < 0) {
            x = -x;
            y = -y;
        }
        const z = pio4 - x;
        const w = pio4lo - y;
        x = z + w;
        y = 0.0;
    }
    const z = x * x;
    var w = z * z;
    // Break x^5*(T[1]+x^2*T[2]+...) into
    // x^5(T[1]+x^4*T[3]+...+x^20*T[11]) + x^5(x^2*(T[2]+x^4*T[4]+...+x^22*[T12])).
    var r = T[1] + w * (T[3] + w * (T[5] + w * (T[7] + w * (T[9] + w * T[11]))));
    var v = z * (T[2] + w * (T[4] + w * (T[6] + w * (T[8] + w * (T[10] + w * T[12])))));
    var s = z * x;
    r = y + z * (s * (r + v) + y);
    r += T[0] * s;
    w = x + r;
    if (ix >= 0x3FE59428) {
        v = @floatFromInt(iy);
        return @as(f64, @floatFromInt(1 - ((hx >> 30) & 2))) * (v - 2.0 * (x - (w * w / (w + v) - r)));
    }
    if (iy == 1) {
        return w;
    }
    // Compute -1.0 / (x+r) accurately.
    const zz = withLow(w, 0);
    v = r - (zz - x); // zz+v = r+x
    const a = -1.0 / w;
    const t = withLow(a, 0);
    s = 1.0 + t * zz;
    return t + a * (s + t * v);
}

/// e_rem_pio2.c: `x` reduced to y[0] + y[1] in [-pi/4, pi/4], and n with x = n*pi/2 + y.
fn remPio2(x: f64, y: *[2]f64) i32 {
    const invpio2 = 6.36619772367581382433e-01; // 0x3FE45F30, 0x6DC9C883
    const pio2_1 = 1.57079632673412561417e+00; // 0x3FF921FB, 0x54400000
    const pio2_1t = 6.07710050650619224932e-11; // 0x3DD0B461, 0x1A626331
    const pio2_2 = 6.07710050630396597660e-11; // 0x3DD0B461, 0x1A600000
    const pio2_2t = 2.02226624879595063154e-21; // 0x3BA3198A, 0x2E037073
    const pio2_3 = 2.02226624871116645580e-21; // 0x3BA3198A, 0x2E000000
    const pio2_3t = 8.47842766036889956997e-32; // 0x397B839A, 0x252049C1
    // The high words of n*pi/2 for n = 1..32.
    const npio2_hw = [_]i32{
        0x3FF921FB, 0x400921FB, 0x4012D97C, 0x401921FB, 0x401F6A7A, 0x4022D97C,
        0x4025FDBB, 0x402921FB, 0x402C463A, 0x402F6A7A, 0x4031475C, 0x4032D97C,
        0x40346B9C, 0x4035FDBB, 0x40378FDB, 0x403921FB, 0x403AB41B, 0x403C463A,
        0x403DD85A, 0x403F6A7A, 0x40407E4C, 0x4041475C, 0x4042106C, 0x4042D97C,
        0x4043A28C, 0x40446B9C, 0x404534AC, 0x4045FDBB, 0x4046C6CB, 0x40478FDB,
        0x404858EB, 0x404921FB,
    };
    const hx = high(x);
    const ix = hx & 0x7fffffff;
    if (ix <= 0x3fe921fb) { // |x| ~<= pi/4, no need for reduction
        y.* = .{ x, 0 };
        return 0;
    }
    if (ix < 0x4002d97c) { // |x| < 3pi/4, special case with n = +-1
        if (hx > 0) {
            var z = x - pio2_1;
            if (ix != 0x3ff921fb) { // 33+53 bit pi is good enough
                y[0] = z - pio2_1t;
                y[1] = (z - y[0]) - pio2_1t;
            } else { // near pi/2, use 33+33+53 bit pi
                z -= pio2_2;
                y[0] = z - pio2_2t;
                y[1] = (z - y[0]) - pio2_2t;
            }
            return 1;
        }
        var z = x + pio2_1;
        if (ix != 0x3ff921fb) {
            y[0] = z + pio2_1t;
            y[1] = (z - y[0]) + pio2_1t;
        } else {
            z += pio2_2;
            y[0] = z + pio2_2t;
            y[1] = (z - y[0]) + pio2_2t;
        }
        return -1;
    }
    if (ix <= 0x413921fb) { // |x| ~<= 2^19*(pi/2), medium size
        var t = @abs(x);
        const n: i32 = @intFromFloat(t * invpio2 + 0.5);
        const f: f64 = @floatFromInt(n);
        var r = t - f * pio2_1;
        var w = f * pio2_1t; // 1st round good to 85 bit
        if (n < 32 and ix != npio2_hw[@intCast(n - 1)]) {
            y[0] = r - w; // quick check no cancellation
        } else {
            const j = ix >> 20;
            y[0] = r - w;
            var i = j - ((high(y[0]) >> 20) & 0x7ff);
            if (i > 16) { // 2nd iteration needed, good to 118
                t = r;
                w = f * pio2_2;
                r = t - w;
                w = f * pio2_2t - ((t - r) - w);
                y[0] = r - w;
                i = j - ((high(y[0]) >> 20) & 0x7ff);
                if (i > 49) { // 3rd iteration needed, 151 bits acc
                    t = r;
                    w = f * pio2_3;
                    r = t - w;
                    w = f * pio2_3t - ((t - r) - w);
                    y[0] = r - w;
                }
            }
        }
        y[1] = (r - y[0]) - w;
        if (hx < 0) {
            y[0] = -y[0];
            y[1] = -y[1];
            return -n;
        }
        return n;
    }
    if (ix >= 0x7ff00000) { // inf or NaN
        y.* = .{ x - x, x - x };
        return 0;
    }
    // z = scalbn(|x|, ilogb(x) - 23), in 24-bit pieces.
    const e0 = (ix >> 20) - 1046;
    var z = fromWords(ix - (e0 << 20), low(x));
    var tx: [3]f64 = undefined;
    for (0..2) |i| {
        tx[i] = @floatFromInt(@as(i32, @intFromFloat(z)));
        z = (z - tx[i]) * 1.67772160000000000000e+07;
    }
    tx[2] = z;
    var nx: usize = 3;
    while (tx[nx - 1] == 0) {
        nx -= 1;
    }
    var ty: [2]f64 = undefined;
    const n = rem_pio2_large(tx[0..nx], &ty, e0, @intCast(nx), 1);
    if (hx < 0) {
        y.* = .{ -ty[0], -ty[1] };
        return -n;
    }
    y.* = ty;
    return n;
}

pub fn sin(x: f64) f64 {
    const ix = high(x) & 0x7fffffff;
    if (ix <= 0x3fe921fb) {
        return kernelSin(x, 0, 0);
    }
    if (ix >= 0x7ff00000) {
        return x - x;
    }
    var y: [2]f64 = undefined;
    const n = remPio2(x, &y);
    return switch (n & 3) {
        0 => kernelSin(y[0], y[1], 1),
        1 => kernelCos(y[0], y[1]),
        2 => -kernelSin(y[0], y[1], 1),
        else => -kernelCos(y[0], y[1]),
    };
}

pub fn cos(x: f64) f64 {
    const ix = high(x) & 0x7fffffff;
    if (ix <= 0x3fe921fb) {
        return kernelCos(x, 0);
    }
    if (ix >= 0x7ff00000) {
        return x - x;
    }
    var y: [2]f64 = undefined;
    const n = remPio2(x, &y);
    return switch (n & 3) {
        0 => kernelCos(y[0], y[1]),
        1 => -kernelSin(y[0], y[1], 1),
        2 => -kernelCos(y[0], y[1]),
        else => kernelSin(y[0], y[1], 1),
    };
}

pub fn tan(x: f64) f64 {
    const ix = high(x) & 0x7fffffff;
    if (ix <= 0x3fe921fb) {
        return kernelTan(x, 0, 1);
    }
    if (ix >= 0x7ff00000) {
        return x - x;
    }
    var y: [2]f64 = undefined;
    const n = remPio2(x, &y);
    return kernelTan(y[0], y[1], 1 - ((n & 1) << 1));
}

// Exponentials and logarithms.

const ln2_hi = 6.93147180369123816490e-01; // 0x3fe62e42, 0xfee00000
const ln2_lo = 1.90821492927058770002e-10; // 0x3dea39ef, 0x35793c76
const two54 = 1.80143985094819840000e+16; // 0x43500000, 0x00000000

/// e_exp.c
pub fn exp(x_: f64) f64 {
    const o_threshold = 7.09782712893383973096e+02; // 0x40862E42, 0xFEFA39EF
    const u_threshold = -7.45133219101941108420e+02; // 0xc0874910, 0xD52D3051
    const invln2 = 1.44269504088896338700e+00; // 0x3ff71547, 0x652b82fe
    const P1 = 1.66666666666666019037e-01; // 0x3FC55555, 0x5555553E
    const P2 = -2.77777777770155933842e-03; // 0xBF66C16C, 0x16BEBD93
    const P3 = 6.61375632143793436117e-05; // 0x3F11566A, 0xAF25DE2C
    const P4 = -1.65339022054652515390e-06; // 0xBEBBBD41, 0xC5D26BF1
    const P5 = 4.13813679705723846039e-08; // 0x3E663769, 0x72BEA4D0
    const twom1000 = 9.33263618503218878990e-302; // 2**-1000
    const half = [2]f64{ 0.5, -0.5 };
    const ln2HI = [2]f64{ ln2_hi, -ln2_hi };
    const ln2LO = [2]f64{ ln2_lo, -ln2_lo };

    var x = x_;
    var hx: u32 = @bitCast(high(x));
    const xsb: usize = hx >> 31;
    hx &= 0x7fffffff;
    var hi: f64 = 0;
    var lo: f64 = 0;
    var k: i32 = 0;

    if (hx >= 0x40862E42) { // |x| >= 709.78...
        if (hx >= 0x7ff00000) {
            if (((hx & 0xfffff) | low(x)) != 0) {
                return x + x; // NaN
            }
            return if (xsb == 0) x else 0.0; // exp(+-inf) = {inf, 0}
        }
        if (x > o_threshold) {
            return std.math.inf(f64);
        }
        if (x < u_threshold) {
            return 0;
        }
    }

    if (hx > 0x3fd62e42) { // |x| > 0.5 ln2
        if (hx < 0x3FF0A2B2) { // and |x| < 1.5 ln2
            // V8 gives exp(1) exactly `Math.E`, which the computation below is one bit off from.
            if (x == 1.0) {
                return std.math.e;
            }
            hi = x - ln2HI[xsb];
            lo = ln2LO[xsb];
            k = 1 - @as(i32, @intCast(xsb)) - @as(i32, @intCast(xsb));
        } else {
            k = @intFromFloat(invln2 * x + half[xsb]);
            const t: f64 = @floatFromInt(k);
            hi = x - t * ln2HI[0]; // t * ln2HI is exact here
            lo = t * ln2LO[0];
        }
        x = hi - lo;
    } else if (hx < 0x3e300000) { // |x| < 2**-28
        return 1.0 + x;
    } else {
        k = 0;
    }

    const t = x * x;
    const twopk = if (k >= -1021) fromWords(0x3ff00000 + (k << 20), 0) else fromWords(0x3ff00000 + ((k + 1000) << 20), 0);
    const c = x - t * (P1 + t * (P2 + t * (P3 + t * (P4 + t * P5))));
    if (k == 0) {
        return 1.0 - ((x * c) / (c - 2.0) - x);
    }
    const y = 1.0 - ((lo - (x * c) / (2.0 - c)) - hi);
    if (k >= -1021) {
        if (k == 1024) {
            return y * 2.0 * 0x1p1023;
        }
        return y * twopk;
    }
    return y * twopk * twom1000;
}

const Lg1 = 6.666666666666735130e-01; // 3FE55555 55555593
const Lg2 = 3.999999999940941908e-01; // 3FD99999 9997FA04
const Lg3 = 2.857142874366239149e-01; // 3FD24924 94229359
const Lg4 = 2.222219843214978396e-01; // 3FCC71C5 1D8E78AF
const Lg5 = 1.818357216161805012e-01; // 3FC74664 96CB03DE
const Lg6 = 1.531383769920937332e-01; // 3FC39A09 D078C69F
const Lg7 = 1.479819860511658591e-01; // 3FC2F112 DF3E5244

/// e_log.c
pub fn log(x_: f64) f64 {
    var x = x_;
    var hx = high(x);
    const lx = low(x);
    var k: i32 = 0;
    if (hx < 0x00100000) { // x < 2**-1022
        if (((hx & 0x7fffffff) | @as(i32, @bitCast(lx))) == 0) {
            return -std.math.inf(f64); // log(+-0) = -inf
        }
        if (hx < 0) {
            return std.math.nan(f64); // log(-#) = NaN
        }
        k -= 54;
        x *= two54; // subnormal number, scale up x
        hx = high(x);
    }
    if (hx >= 0x7ff00000) {
        return x + x;
    }
    k += (hx >> 20) - 1023;
    hx &= 0x000fffff;
    const i = (hx + 0x95f64) & 0x100000;
    x = withHigh(x, hx | (i ^ 0x3ff00000)); // normalize x or x/2
    k += i >> 20;
    const f = x - 1.0;
    const dk: f64 = @floatFromInt(k);
    if ((0x000fffff & (2 + hx)) < 3) { // -2**-20 <= f < 2**-20
        if (f == 0) {
            if (k == 0) {
                return 0;
            }
            return dk * ln2_hi + dk * ln2_lo;
        }
        const R = f * f * (0.5 - 0.33333333333333333 * f);
        if (k == 0) {
            return f - R;
        }
        return dk * ln2_hi - ((R - dk * ln2_lo) - f);
    }
    const s = f / (2.0 + f);
    const z = s * s;
    var j = hx - 0x6147a;
    const w = z * z;
    const t1 = w * (Lg2 + w * (Lg4 + w * Lg6));
    const t2 = z * (Lg1 + w * (Lg3 + w * (Lg5 + w * Lg7)));
    j |= 0x6b851 - hx;
    const R = t2 + t1;
    if (j > 0) {
        const hfsq = 0.5 * f * f;
        if (k == 0) {
            return f - (hfsq - s * (hfsq + R));
        }
        return dk * ln2_hi - ((hfsq - (s * (hfsq + R) + dk * ln2_lo)) - f);
    }
    if (k == 0) {
        return f - s * (f - R);
    }
    return dk * ln2_hi - ((s * (f - R) - dk * ln2_lo) - f);
}

/// k_log.h: log(1 + f) - f + f*f/2, for `f` in [sqrt(2)/2 - 1, sqrt(2) - 1].
fn kLog1p(f: f64) f64 {
    const s = f / (2.0 + f);
    const z = s * s;
    const w = z * z;
    const t1 = w * (Lg2 + w * (Lg4 + w * Lg6));
    const t2 = z * (Lg1 + w * (Lg3 + w * (Lg5 + w * Lg7)));
    const R = t2 + t1;
    const hfsq = 0.5 * f * f;
    return s * (hfsq + R);
}

/// The shared start of e_log2.c and e_log10.c: `x` split into `2^k * (1 + f)`. Null with the
/// result for the special cases.
fn reduceLog(x_: f64) union(enum) { done: f64, reduced: struct { k: f64, f: f64 } } {
    var x = x_;
    var hx = high(x);
    const lx = low(x);
    var k: i32 = 0;
    if (hx < 0x00100000) {
        if (((hx & 0x7fffffff) | @as(i32, @bitCast(lx))) == 0) {
            return .{ .done = -std.math.inf(f64) };
        }
        if (hx < 0) {
            return .{ .done = std.math.nan(f64) };
        }
        k -= 54;
        x *= two54;
        hx = high(x);
    }
    if (hx >= 0x7ff00000) {
        return .{ .done = x + x };
    }
    if (hx == 0x3ff00000 and lx == 0) {
        return .{ .done = 0 }; // log(1) = +0
    }
    k += (hx >> 20) - 1023;
    hx &= 0x000fffff;
    const i = (hx + 0x95f64) & 0x100000;
    x = withHigh(x, hx | (i ^ 0x3ff00000));
    k += i >> 20;
    return .{ .reduced = .{ .k = @floatFromInt(k), .f = x - 1.0 } };
}

/// e_log2.c
pub fn log2(x: f64) f64 {
    const ivln2hi = 1.44269504072144627571e+00; // 0x3ff71547, 0x65200000
    const ivln2lo = 1.67517131648865118353e-10; // 0x3de705fc, 0x2eefa200
    const r = switch (reduceLog(x)) {
        .done => |v| return v,
        .reduced => |r| r,
    };
    const f = r.f;
    const hfsq = 0.5 * f * f;
    const rest = kLog1p(f);
    // f - hfsq in extra precision, to avoid a large cancellation near sqrt(2) and sqrt(2)/2.
    const hi = withLow(f - hfsq, 0);
    const lo = (f - hi) - hfsq + rest;
    var val_hi = hi * ivln2hi;
    var val_lo = (lo + hi) * ivln2lo + lo * ivln2hi;
    const w = r.k + val_hi;
    val_lo += (r.k - w) + val_hi;
    val_hi = w;
    return val_lo + val_hi;
}

/// e_log10.c, the original fdlibm one: log10(x) = (n*log10_2lo + ivln10*log(x)) + n*log10_2hi.
pub fn log10(x_: f64) f64 {
    const ivln10 = 4.34294481903251816668e-01; // 0x3FDBCB7B, 0x1526E50E
    const log10_2hi = 3.01029995663611771306e-01; // 0x3FD34413, 0x509F6000
    const log10_2lo = 3.69423907715893078616e-13; // 0x3D59FEF3, 0x11F12B36
    var x = x_;
    var hx = high(x);
    const lx = low(x);
    var k: i32 = 0;
    if (hx < 0x00100000) { // x < 2**-1022
        if (((hx & 0x7fffffff) | @as(i32, @bitCast(lx))) == 0) {
            return -std.math.inf(f64);
        }
        if (hx < 0) {
            return std.math.nan(f64);
        }
        k -= 54;
        x *= two54;
        hx = high(x);
    }
    if (hx >= 0x7ff00000) {
        return x + x;
    }
    k += (hx >> 20) - 1023;
    const i: i32 = @intCast(@as(u32, @bitCast(k)) >> 31);
    hx = (hx & 0x000fffff) | ((0x3ff - i) << 20);
    const y: f64 = @floatFromInt(k + i);
    x = withHigh(x, hx);
    const z = y * log10_2lo + ivln10 * log(x);
    return z + y * log10_2hi;
}

// Hyperbolic functions.

/// e_sinh.c
pub fn sinh(x: f64) f64 {
    const jx = high(x);
    const ix = jx & 0x7fffffff;
    if (ix >= 0x7ff00000) {
        return x + x;
    }
    const h: f64 = if (jx < 0) -0.5 else 0.5;
    if (ix < 0x40360000) { // |x| < 22
        if (ix < 0x3e300000) { // |x| < 2**-28
            return x;
        }
        const t = expm1(@abs(x));
        if (ix < 0x3ff00000) {
            return h * (2.0 * t - t * t / (t + 1.0));
        }
        return h * (t + t / (t + 1.0));
    }
    if (ix < 0x40862E42) { // |x| in [22, log(maxdouble)]
        return h * exp(@abs(x));
    }
    // |x| in [log(maxdouble), overflow threshold]
    if (@abs(x) <= 7.10475860073943863426e+02) {
        const w = exp(0.5 * @abs(x));
        const t = h * w;
        return t * w;
    }
    return x * 1.0e307;
}

/// e_cosh.c
pub fn cosh(x: f64) f64 {
    const ix = high(x) & 0x7fffffff;
    if (ix >= 0x7ff00000) {
        return x * x;
    }
    if (ix < 0x3fd62e43) { // |x| in [0, 0.5*ln2]
        const t = expm1(@abs(x));
        const w = 1.0 + t;
        if (ix < 0x3c800000) {
            return w; // cosh(tiny) = 1
        }
        return 1.0 + (t * t) / (w + w);
    }
    if (ix < 0x40360000) { // |x| in [0.5*ln2, 22]
        const t = exp(@abs(x));
        return 0.5 * t + 0.5 / t;
    }
    if (ix < 0x40862E42) { // |x| in [22, log(maxdouble)]
        return 0.5 * exp(@abs(x));
    }
    if (@abs(x) <= 7.10475860073943863426e+02) {
        const w = exp(0.5 * @abs(x));
        const t = 0.5 * w;
        return t * w;
    }
    return std.math.inf(f64);
}

/// s_tanh.c
pub fn tanh(x: f64) f64 {
    const jx = high(x);
    const ix = jx & 0x7fffffff;
    if (ix >= 0x7ff00000) {
        return if (jx >= 0) 1.0 / x + 1.0 else 1.0 / x - 1.0;
    }
    var z: f64 = undefined;
    if (ix < 0x40360000) { // |x| < 22
        if (ix < 0x3e300000) { // |x| < 2**-28
            return x;
        }
        if (ix >= 0x3ff00000) { // |x| >= 1
            const t = expm1(2.0 * @abs(x));
            z = 1.0 - 2.0 / (t + 2.0);
        } else {
            const t = expm1(-2.0 * @abs(x));
            z = -t / (t + 2.0);
        }
    } else {
        z = 1.0;
    }
    return if (jx >= 0) z else -z;
}

const ln2 = 6.93147180559945286227e-01; // 0x3FE62E42, 0xFEFA39EF

/// e_acosh.c
pub fn acosh(x: f64) f64 {
    const hx = high(x);
    if (hx < 0x3ff00000) { // x < 1
        return std.math.nan(f64);
    }
    if (hx >= 0x41b00000) { // x > 2**28
        if (hx >= 0x7ff00000) {
            return x + x;
        }
        return log(x) + ln2;
    }
    if (((hx - 0x3ff00000) | @as(i32, @bitCast(low(x)))) == 0) {
        return 0; // acosh(1) = 0
    }
    if (hx > 0x40000000) { // 2**28 > x > 2
        const t = x * x;
        return log(2.0 * x - 1.0 / (x + @sqrt(t - 1.0)));
    }
    const t = x - 1.0; // 1 < x < 2
    return log1p(t + @sqrt(2.0 * t + t * t));
}

/// s_asinh.c
pub fn asinh(x: f64) f64 {
    const hx = high(x);
    const ix = hx & 0x7fffffff;
    if (ix >= 0x7ff00000) {
        return x + x;
    }
    if (ix < 0x3e300000) { // |x| < 2**-28
        return x;
    }
    var w: f64 = undefined;
    if (ix > 0x41b00000) { // |x| > 2**28
        w = log(@abs(x)) + ln2;
    } else if (ix > 0x40000000) { // 2**28 > |x| > 2
        const t = @abs(x);
        w = log(2.0 * t + 1.0 / (@sqrt(x * x + 1.0) + t));
    } else { // 2 > |x| > 2**-28
        const t = x * x;
        w = log1p(@abs(x) + t / (1.0 + @sqrt(1.0 + t)));
    }
    return if (hx > 0) w else -w;
}

/// e_atanh.c
pub fn atanh(x: f64) f64 {
    const hx = high(x);
    const lx = low(x);
    const ix = hx & 0x7fffffff;
    if ((@as(u32, @bitCast(ix)) | ((lx | (0 -% lx)) >> 31)) > 0x3ff00000) { // |x| > 1
        return std.math.nan(f64);
    }
    if (ix == 0x3ff00000) {
        return if (hx > 0) std.math.inf(f64) else -std.math.inf(f64);
    }
    if (ix < 0x3e300000) { // x < 2**-28
        return x;
    }
    const a = withHigh(x, ix); // |x|
    var t: f64 = undefined;
    if (ix < 0x3fe00000) { // |x| < 0.5
        t = a + a;
        t = 0.5 * log1p(t + t * a / (1.0 - a));
    } else {
        t = 0.5 * log1p((a + a) / (1.0 - a));
    }
    return if (hx >= 0) t else -t;
}

// pow, which V8 leaves to the C library's: glibc's and Apple's are correctly rounded (but for
// cases too close to call), so this is too, computed in double-double arithmetic.

/// A number as the unevaluated sum of two doubles, `hi + lo`, with |lo| at most half an ulp of
/// `hi`: about 106 bits.
const Double = struct {
    hi: f64,
    lo: f64 = 0,

    fn sum(a: f64, b: f64) Double {
        const s = a + b;
        const v = s - a;
        return .{ .hi = s, .lo = (a - (s - v)) + (b - v) };
    }

    fn product(a: f64, b: f64) Double {
        const p = a * b;
        return .{ .hi = p, .lo = @mulAdd(f64, a, b, -p) };
    }

    fn add(a: Double, b: Double) Double {
        const s = sum(a.hi, b.hi);
        const t = sum(a.lo, b.lo);
        var r = sum(s.hi, s.lo + t.hi);
        r = sum(r.hi, r.lo + t.lo);
        return r;
    }

    fn mul(a: Double, b: Double) Double {
        const p = product(a.hi, b.hi);
        return sum(p.hi, p.lo + (a.hi * b.lo + a.lo * b.hi));
    }

    fn scale(a: Double, b: f64) Double {
        const p = product(a.hi, b);
        return sum(p.hi, p.lo + a.lo * b);
    }

    fn neg(a: Double) Double {
        return .{ .hi = -a.hi, .lo = -a.lo };
    }
};

/// ln 2 to about 160 bits, in three parts.
const ln2_parts = [3]f64{ 0x1.62e42fefa39efp-1, 0x1.abc9e3b39803fp-56, 0x1.7b57a079a1934p-111 };

/// exp(z) for |z| below about 709.7, as a double-double.
fn expDouble(z: Double) Double {
    // z = k ln 2 + r, |r| <= ln 2 / 2.
    const k = @round(z.hi / ln2_parts[0]);
    var r = z.add(Double.product(-k, ln2_parts[0]));
    r = r.add(Double.product(-k, ln2_parts[1]));
    r = r.add(.{ .hi = -k * ln2_parts[2] });
    // exp(r) = (exp(r / 2^8))^(2^8), with a Taylor series for the small part.
    const reduced = r.scale(1.0 / 256.0);
    var term: Double = .{ .hi = 1 };
    var total: Double = .{ .hi = 1 };
    var n: f64 = 1;
    while (n < 20) : (n += 1) {
        term = term.mul(reduced).scale(1.0 / n);
        total = total.add(term);
    }
    for (0..8) |_| {
        total = total.mul(total);
    }
    const two_k = std.math.ldexp(@as(f64, 1), @intFromFloat(k));
    return .{ .hi = total.hi * two_k, .lo = total.lo * two_k };
}

/// ln(x) for positive finite `x`, as a double-double: fdlibm's, improved by a Newton step.
fn logDouble(x: f64) Double {
    // Scaled to near 1 first, so exp of the estimate can't overflow.
    const parts = std.math.frexp(x);
    const m = parts.significand * 2;
    const e: f64 = @floatFromInt(parts.exponent - 1);
    const estimate = log(m);
    // ln m = l + m * exp(-l) - 1, to twice the precision.
    const correction = expDouble(.{ .hi = -estimate }).scale(m).add(.{ .hi = -1 });
    const ln_m = Double.sum(estimate, correction.hi).add(.{ .hi = correction.lo });
    const ln_2e = Double.product(e, ln2_parts[0]).add(Double.product(e, ln2_parts[1]));
    return ln_m.add(ln_2e);
}

/// pow (§6.1.6.1.3 Number::exponentiate, which the caller has handled NaN and ±1 to ±Infinity
/// for), with the C library's special cases.
pub fn pow(x: f64, y: f64) f64 {
    if (y == 0) {
        return 1;
    }
    if (std.math.isNan(x) or std.math.isNan(y)) {
        return std.math.nan(f64);
    }
    const y_integer = @trunc(y) == y;
    const y_odd = y_integer and @abs(y) < 9007199254740992.0 and @mod(y, 2) != 0;
    if (x == 0) {
        if (y < 0) {
            return if (y_odd) std.math.copysign(std.math.inf(f64), x) else std.math.inf(f64);
        }
        return if (y_odd) x else 0;
    }
    if (std.math.isInf(y)) {
        const a = @abs(x);
        if (a == 1) {
            return std.math.nan(f64);
        }
        return if ((a > 1) == (y > 0)) std.math.inf(f64) else 0;
    }
    if (std.math.isInf(x)) {
        if (x > 0) {
            return if (y > 0) std.math.inf(f64) else 0;
        }
        const magnitude: f64 = if (y > 0) std.math.inf(f64) else 0;
        return if (y_odd) -magnitude else magnitude;
    }
    if (x < 0 and !y_integer) {
        return std.math.nan(f64);
    }
    const sign: f64 = if (x < 0 and y_odd) -1 else 1;
    const a = @abs(x);
    if (a == 1) {
        return sign;
    }
    if (y == 1) {
        return x;
    }
    if (y == 2) {
        return x * x;
    }
    if (y == 0.5) {
        return @sqrt(x);
    }
    const z = logDouble(a).scale(y);
    // Past what a double holds, or below its smallest subnormal.
    if (z.hi > 709.8) {
        return sign * std.math.inf(f64);
    }
    if (z.hi < -745.2) {
        return sign * 0;
    }
    if (z.hi < -708) {
        // Subnormal: worked out scaled up, so it's rounded once.
        const scaled = expDouble(z.add(.{ .hi = 200 * ln2_parts[0], .lo = 200 * ln2_parts[1] }));
        return sign * std.math.ldexp(scaled.hi + scaled.lo, -200);
    }
    const r = expDouble(z);
    return sign * (r.hi + r.lo);
}

const testing = std.testing;

test "matches V8" {
    // What node prints, where a correctly rounded result would differ.
    try testing.expectEqual(@as(f64, 0.9950041652780257), cos(0.1));
    try testing.expectEqual(@as(f64, 1.0986122886681096), log(3));
    try testing.expectEqual(@as(f64, 2.718281828459045), exp(1));
    try testing.expectEqual(@as(f64, 1024), pow(2, 10));
    try testing.expectEqual(@as(f64, 0.3535533905932738), pow(0.5, 1.5));
    try testing.expectEqual(@as(f64, 5.656854249492381), pow(2, 2.5));
    try testing.expect(std.math.isNan(pow(1, std.math.inf(f64))));
    try testing.expectEqual(@as(f64, 3), log2(8));
    try testing.expectEqual(@as(f64, 3), log10(1000));
}
