// The builtins, which the checker reads like any `.d.ts` file and `src/runtime/builtins`
// implements. These follow TypeScript's `lib.es2022.d.ts`, with what we don't implement yet left
// out (the checker reports using it as ZV9001) and a few simplifications where our type system
// can't say what tsc's does:
//
// - Declarations tsc spreads over several interfaces of the same name are merged into one here,
//   with the overloads in the order tsc tries them (a later declaration's first).
// - `this` types are written out (`Map<K, V>` for `this`), and `this` parameters are left out.
//   `every` has its type guard overload, but it doesn't narrow the array (`this is S[]`).
// - `PropertyKey` doesn't include `symbol`, and nothing mentions `bigint` or `symbol`, which we
//   don't have. `Object.freeze` has no overload for functions, which `Readonly` leaves alone.
// - `FlatArray` is computed by the checker, since it's a conditional type.
//
// A test in `src/runtime/builtins.zig` checks that every value and member declared here has a
// native implementation, and the other way round.

// Utility types

/** Make all properties in T optional. */
type Partial<T> = {
    [P in keyof T]?: T[P];
};

/** Make all properties in T required. */
type Required<T> = {
    [P in keyof T]-?: T[P];
};

/** Make all properties in T readonly. */
type Readonly<T> = {
    readonly [P in keyof T]: T[P];
};

/** From T, pick a set of properties whose keys are in the union K. */
type Pick<T, K extends keyof T> = {
    [P in K]: T[P];
};

/** Construct a type with a set of properties K of type T. */
type Record<K extends keyof any, T> = {
    [P in K]: T;
};

type PropertyKey = string | number;

interface ArrayLike<T> {
    readonly length: number;
    readonly [n: number]: T;
}

interface ConcatArray<T> {
    readonly length: number;
    readonly [n: number]: T;
    join(separator?: string): string;
    slice(start?: number, end?: number): T[];
}

type FlatArray<Arr, Depth extends number> = intrinsic;

// Iteration

interface IteratorYieldResult<TYield> {
    done?: false;
    value: TYield;
}

interface IteratorReturnResult<TReturn> {
    done: true;
    value: TReturn;
}

type IteratorResult<T, TReturn = any> = IteratorYieldResult<T> | IteratorReturnResult<TReturn>;

interface Iterator<T, TReturn = any, TNext = any> {
    next(): IteratorResult<T, TReturn>;
}

interface Iterable<T, TReturn = any, TNext = any> {
    [Symbol.iterator](): Iterator<T, TReturn, TNext>;
}

interface IterableIterator<T, TReturn = any, TNext = any> extends Iterator<T, TReturn, TNext> {
    [Symbol.iterator](): IterableIterator<T, TReturn, TNext>;
}

interface IteratorObject<T, TReturn = unknown, TNext = unknown> extends Iterator<T, TReturn, TNext> {
    [Symbol.iterator](): IteratorObject<T, TReturn, TNext>;
}

/** What the builtin iterators return when they're done, which `strict` makes `undefined`. */
type BuiltinIteratorReturn = undefined;

interface ArrayIterator<T> extends IteratorObject<T, BuiltinIteratorReturn, unknown> {
    [Symbol.iterator](): ArrayIterator<T>;
}

interface MapIterator<T> extends IteratorObject<T, BuiltinIteratorReturn, unknown> {
    [Symbol.iterator](): MapIterator<T>;
}

interface SetIterator<T> extends IteratorObject<T, BuiltinIteratorReturn, unknown> {
    [Symbol.iterator](): SetIterator<T>;
}

interface StringIterator<T> extends IteratorObject<T, BuiltinIteratorReturn, unknown> {
    [Symbol.iterator](): StringIterator<T>;
}

// Object

interface Object {
    toString(): string;
    valueOf(): Object;
    hasOwnProperty(v: PropertyKey): boolean;
}

interface ObjectConstructor {
    keys(o: {}): string[];
    keys(o: object): string[];
    values<T>(o: { [s: string]: T } | ArrayLike<T>): T[];
    values(o: {}): any[];
    entries<T>(o: { [s: string]: T } | ArrayLike<T>): [string, T][];
    entries(o: {}): [string, any][];
    assign<T extends {}, U>(target: T, source: U): T & U;
    assign<T extends {}, U, V>(target: T, source1: U, source2: V): T & U & V;
    assign<T extends {}, U, V, W>(target: T, source1: U, source2: V, source3: W): T & U & V & W;
    assign(target: object, ...sources: any[]): any;
    freeze<T extends { [idx: string]: U | null | undefined | object }, U extends string | number | boolean>(o: T): Readonly<T>;
    freeze<T>(o: T): Readonly<T>;
    isFrozen(o: any): boolean;
    fromEntries<T = any>(entries: Iterable<readonly [PropertyKey, T]>): { [k: string]: T };
    fromEntries(entries: Iterable<readonly any[]>): any;
    hasOwn(o: object, v: PropertyKey): boolean;
    readonly prototype: Object;
}

declare var Object: ObjectConstructor;

// Primitives

interface Boolean {
    valueOf(): boolean;
}

interface BooleanConstructor {
    <T>(value?: T): boolean;
}

declare var Boolean: BooleanConstructor;

interface Number {
    toString(radix?: number): string;
    toFixed(fractionDigits?: number): string;
    toExponential(fractionDigits?: number): string;
    toPrecision(precision?: number): string;
    valueOf(): number;
}

interface NumberConstructor {
    (value?: any): number;
    readonly MAX_VALUE: number;
    readonly MIN_VALUE: number;
    readonly NaN: number;
    readonly NEGATIVE_INFINITY: number;
    readonly POSITIVE_INFINITY: number;
    readonly EPSILON: number;
    readonly MAX_SAFE_INTEGER: number;
    readonly MIN_SAFE_INTEGER: number;
    isFinite(number: unknown): boolean;
    isInteger(number: unknown): boolean;
    isNaN(number: unknown): boolean;
    isSafeInteger(number: unknown): boolean;
    parseFloat(string: string): number;
    parseInt(string: string, radix?: number): number;
}

declare var Number: NumberConstructor;

declare var NaN: number;
declare var Infinity: number;
declare function parseInt(string: string, radix?: number): number;
declare function parseFloat(string: string): number;
declare function isNaN(number: number): boolean;
declare function isFinite(number: number): boolean;

interface String {
    toString(): string;
    charAt(pos: number): string;
    charCodeAt(index: number): number;
    concat(...strings: string[]): string;
    indexOf(searchString: string, position?: number): number;
    lastIndexOf(searchString: string, position?: number): number;
    replace(searchValue: string, replaceValue: string): string;
    replace(searchValue: string, replacer: (substring: string, ...args: any[]) => string): string;
    slice(start?: number, end?: number): string;
    split(separator: string, limit?: number): string[];
    split(splitter: { [Symbol.split](string: string, limit?: number): string[] }, limit?: number): string[];
    substring(start: number, end?: number): string;
    toLowerCase(): string;
    toUpperCase(): string;
    trim(): string;
    readonly length: number;
    substr(from: number, length?: number): string;
    valueOf(): string;
    readonly [index: number]: string;
    codePointAt(pos: number): number | undefined;
    includes(searchString: string, position?: number): boolean;
    endsWith(searchString: string, endPosition?: number): boolean;
    repeat(count: number): string;
    startsWith(searchString: string, position?: number): boolean;
    padStart(maxLength: number, fillString?: string): string;
    padEnd(maxLength: number, fillString?: string): string;
    trimEnd(): string;
    trimStart(): string;
    replaceAll(searchValue: string, replaceValue: string): string;
    replaceAll(searchValue: string, replacer: (substring: string, ...args: any[]) => string): string;
    at(index: number): string | undefined;
    [Symbol.iterator](): StringIterator<string>;
}

interface StringConstructor {
    (value?: any): string;
    fromCharCode(...codes: number[]): string;
    fromCodePoint(...codePoints: number[]): string;
}

declare var String: StringConstructor;

// Math

interface Math {
    readonly E: number;
    readonly LN10: number;
    readonly LN2: number;
    readonly LOG2E: number;
    readonly LOG10E: number;
    readonly PI: number;
    readonly SQRT1_2: number;
    readonly SQRT2: number;
    abs(x: number): number;
    acos(x: number): number;
    asin(x: number): number;
    atan(x: number): number;
    atan2(y: number, x: number): number;
    ceil(x: number): number;
    cos(x: number): number;
    exp(x: number): number;
    floor(x: number): number;
    log(x: number): number;
    max(...values: number[]): number;
    min(...values: number[]): number;
    pow(x: number, y: number): number;
    random(): number;
    round(x: number): number;
    sin(x: number): number;
    sqrt(x: number): number;
    tan(x: number): number;
    clz32(x: number): number;
    imul(x: number, y: number): number;
    sign(x: number): number;
    log10(x: number): number;
    log2(x: number): number;
    log1p(x: number): number;
    expm1(x: number): number;
    cosh(x: number): number;
    sinh(x: number): number;
    tanh(x: number): number;
    acosh(x: number): number;
    asinh(x: number): number;
    atanh(x: number): number;
    hypot(...values: number[]): number;
    trunc(x: number): number;
    fround(x: number): number;
    cbrt(x: number): number;
}

declare var Math: Math;

// Arrays

interface Array<T> {
    length: number;
    toString(): string;
    pop(): T | undefined;
    push(...items: T[]): number;
    concat(...items: ConcatArray<T>[]): T[];
    concat(...items: (T | ConcatArray<T>)[]): T[];
    join(separator?: string): string;
    reverse(): T[];
    shift(): T | undefined;
    slice(start?: number, end?: number): T[];
    sort(compareFn?: (a: T, b: T) => number): T[];
    splice(start: number, deleteCount?: number): T[];
    splice(start: number, deleteCount: number, ...items: T[]): T[];
    unshift(...items: T[]): number;
    indexOf(searchElement: T, fromIndex?: number): number;
    lastIndexOf(searchElement: T, fromIndex?: number): number;
    every<S extends T>(predicate: (value: T, index: number, array: T[]) => value is S, thisArg?: any): boolean;
    every(predicate: (value: T, index: number, array: T[]) => unknown, thisArg?: any): boolean;
    some(predicate: (value: T, index: number, array: T[]) => unknown, thisArg?: any): boolean;
    forEach(callbackfn: (value: T, index: number, array: T[]) => void, thisArg?: any): void;
    map<U>(callbackfn: (value: T, index: number, array: T[]) => U, thisArg?: any): U[];
    filter<S extends T>(predicate: (value: T, index: number, array: T[]) => value is S, thisArg?: any): S[];
    filter(predicate: (value: T, index: number, array: T[]) => unknown, thisArg?: any): T[];
    reduce(callbackfn: (previousValue: T, currentValue: T, currentIndex: number, array: T[]) => T): T;
    reduce(callbackfn: (previousValue: T, currentValue: T, currentIndex: number, array: T[]) => T, initialValue: T): T;
    reduce<U>(callbackfn: (previousValue: U, currentValue: T, currentIndex: number, array: T[]) => U, initialValue: U): U;
    reduceRight(callbackfn: (previousValue: T, currentValue: T, currentIndex: number, array: T[]) => T): T;
    reduceRight(callbackfn: (previousValue: T, currentValue: T, currentIndex: number, array: T[]) => T, initialValue: T): T;
    reduceRight<U>(callbackfn: (previousValue: U, currentValue: T, currentIndex: number, array: T[]) => U, initialValue: U): U;
    [n: number]: T;
    find<S extends T>(predicate: (value: T, index: number, obj: T[]) => value is S, thisArg?: any): S | undefined;
    find(predicate: (value: T, index: number, obj: T[]) => unknown, thisArg?: any): T | undefined;
    findIndex(predicate: (value: T, index: number, obj: T[]) => unknown, thisArg?: any): number;
    fill(value: T, start?: number, end?: number): T[];
    [Symbol.iterator](): ArrayIterator<T>;
    entries(): ArrayIterator<[number, T]>;
    keys(): ArrayIterator<number>;
    values(): ArrayIterator<T>;
    includes(searchElement: T, fromIndex?: number): boolean;
    flatMap<U>(callback: (value: T, index: number, array: T[]) => U | ReadonlyArray<U>, thisArg?: any): U[];
    flat<D extends number = 1>(depth?: D): FlatArray<T[], D>[];
    at(index: number): T | undefined;
}

interface ReadonlyArray<T> {
    readonly length: number;
    toString(): string;
    concat(...items: ConcatArray<T>[]): T[];
    concat(...items: (T | ConcatArray<T>)[]): T[];
    join(separator?: string): string;
    slice(start?: number, end?: number): T[];
    indexOf(searchElement: T, fromIndex?: number): number;
    lastIndexOf(searchElement: T, fromIndex?: number): number;
    every<S extends T>(predicate: (value: T, index: number, array: readonly T[]) => value is S, thisArg?: any): boolean;
    every(predicate: (value: T, index: number, array: readonly T[]) => unknown, thisArg?: any): boolean;
    some(predicate: (value: T, index: number, array: readonly T[]) => unknown, thisArg?: any): boolean;
    forEach(callbackfn: (value: T, index: number, array: readonly T[]) => void, thisArg?: any): void;
    map<U>(callbackfn: (value: T, index: number, array: readonly T[]) => U, thisArg?: any): U[];
    filter<S extends T>(predicate: (value: T, index: number, array: readonly T[]) => value is S, thisArg?: any): S[];
    filter(predicate: (value: T, index: number, array: readonly T[]) => unknown, thisArg?: any): T[];
    reduce(callbackfn: (previousValue: T, currentValue: T, currentIndex: number, array: readonly T[]) => T): T;
    reduce(callbackfn: (previousValue: T, currentValue: T, currentIndex: number, array: readonly T[]) => T, initialValue: T): T;
    reduce<U>(callbackfn: (previousValue: U, currentValue: T, currentIndex: number, array: readonly T[]) => U, initialValue: U): U;
    reduceRight(callbackfn: (previousValue: T, currentValue: T, currentIndex: number, array: readonly T[]) => T): T;
    reduceRight(callbackfn: (previousValue: T, currentValue: T, currentIndex: number, array: readonly T[]) => T, initialValue: T): T;
    reduceRight<U>(callbackfn: (previousValue: U, currentValue: T, currentIndex: number, array: readonly T[]) => U, initialValue: U): U;
    readonly [n: number]: T;
    find<S extends T>(predicate: (value: T, index: number, obj: readonly T[]) => value is S, thisArg?: any): S | undefined;
    find(predicate: (value: T, index: number, obj: readonly T[]) => unknown, thisArg?: any): T | undefined;
    findIndex(predicate: (value: T, index: number, obj: readonly T[]) => unknown, thisArg?: any): number;
    [Symbol.iterator](): ArrayIterator<T>;
    entries(): ArrayIterator<[number, T]>;
    keys(): ArrayIterator<number>;
    values(): ArrayIterator<T>;
    includes(searchElement: T, fromIndex?: number): boolean;
    flatMap<U>(callback: (value: T, index: number, array: T[]) => U | ReadonlyArray<U>, thisArg?: any): U[];
    flat<D extends number = 1>(depth?: D): FlatArray<T[], D>[];
    at(index: number): T | undefined;
}

interface ArrayConstructor {
    isArray(arg: any): arg is any[];
    from<T>(iterable: Iterable<T> | ArrayLike<T>): T[];
    from<T, U>(iterable: Iterable<T> | ArrayLike<T>, mapfn: (v: T, k: number) => U, thisArg?: any): U[];
    from<T>(arrayLike: ArrayLike<T>): T[];
    from<T, U>(arrayLike: ArrayLike<T>, mapfn: (v: T, k: number) => U, thisArg?: any): U[];
    of<T>(...items: T[]): T[];
    readonly prototype: any[];
}

declare var Array: ArrayConstructor;

// Collections

interface Map<K, V> {
    clear(): void;
    delete(key: K): boolean;
    forEach(callbackfn: (value: V, key: K, map: Map<K, V>) => void, thisArg?: any): void;
    get(key: K): V | undefined;
    has(key: K): boolean;
    set(key: K, value: V): Map<K, V>;
    readonly size: number;
    [Symbol.iterator](): MapIterator<[K, V]>;
    entries(): MapIterator<[K, V]>;
    keys(): MapIterator<K>;
    values(): MapIterator<V>;
}

interface MapConstructor {
    new (): Map<any, any>;
    new <K, V>(iterable?: Iterable<readonly [K, V]> | null): Map<K, V>;
    new (): Map<any, any>;
    new <K, V>(entries?: readonly (readonly [K, V])[] | null): Map<K, V>;
}

declare var Map: MapConstructor;

interface ReadonlyMap<K, V> {
    forEach(callbackfn: (value: V, key: K, map: ReadonlyMap<K, V>) => void, thisArg?: any): void;
    get(key: K): V | undefined;
    has(key: K): boolean;
    readonly size: number;
    [Symbol.iterator](): MapIterator<[K, V]>;
    entries(): MapIterator<[K, V]>;
    keys(): MapIterator<K>;
    values(): MapIterator<V>;
}

interface Set<T> {
    add(value: T): Set<T>;
    clear(): void;
    delete(value: T): boolean;
    forEach(callbackfn: (value: T, value2: T, set: Set<T>) => void, thisArg?: any): void;
    has(value: T): boolean;
    readonly size: number;
    [Symbol.iterator](): SetIterator<T>;
    entries(): SetIterator<[T, T]>;
    keys(): SetIterator<T>;
    values(): SetIterator<T>;
}

interface SetConstructor {
    new <T>(iterable?: Iterable<T> | null): Set<T>;
    new <T = any>(values?: readonly T[] | null): Set<T>;
}

declare var Set: SetConstructor;

interface ReadonlySet<T> {
    forEach(callbackfn: (value: T, value2: T, set: ReadonlySet<T>) => void, thisArg?: any): void;
    has(value: T): boolean;
    readonly size: number;
    [Symbol.iterator](): SetIterator<T>;
    entries(): SetIterator<[T, T]>;
    keys(): SetIterator<T>;
    values(): SetIterator<T>;
}

// Errors. tsc's `lib.es5.d.ts` and `lib.es2022.error.d.ts`, merged.

interface ErrorOptions {
    cause?: unknown;
}

interface Error {
    name: string;
    message: string;
    stack?: string;
    cause?: unknown;
}

interface ErrorConstructor {
    new (message?: string, options?: ErrorOptions): Error;
    (message?: string, options?: ErrorOptions): Error;
    new (message?: string): Error;
    (message?: string): Error;
    readonly prototype: Error;
}

declare var Error: ErrorConstructor;

interface EvalError extends Error {}

interface EvalErrorConstructor extends ErrorConstructor {
    new (message?: string, options?: ErrorOptions): EvalError;
    (message?: string, options?: ErrorOptions): EvalError;
    new (message?: string): EvalError;
    (message?: string): EvalError;
    readonly prototype: EvalError;
}

declare var EvalError: EvalErrorConstructor;

interface RangeError extends Error {}

interface RangeErrorConstructor extends ErrorConstructor {
    new (message?: string, options?: ErrorOptions): RangeError;
    (message?: string, options?: ErrorOptions): RangeError;
    new (message?: string): RangeError;
    (message?: string): RangeError;
    readonly prototype: RangeError;
}

declare var RangeError: RangeErrorConstructor;

interface ReferenceError extends Error {}

interface ReferenceErrorConstructor extends ErrorConstructor {
    new (message?: string, options?: ErrorOptions): ReferenceError;
    (message?: string, options?: ErrorOptions): ReferenceError;
    new (message?: string): ReferenceError;
    (message?: string): ReferenceError;
    readonly prototype: ReferenceError;
}

declare var ReferenceError: ReferenceErrorConstructor;

interface SyntaxError extends Error {}

interface SyntaxErrorConstructor extends ErrorConstructor {
    new (message?: string, options?: ErrorOptions): SyntaxError;
    (message?: string, options?: ErrorOptions): SyntaxError;
    new (message?: string): SyntaxError;
    (message?: string): SyntaxError;
    readonly prototype: SyntaxError;
}

declare var SyntaxError: SyntaxErrorConstructor;

interface TypeError extends Error {}

interface TypeErrorConstructor extends ErrorConstructor {
    new (message?: string, options?: ErrorOptions): TypeError;
    (message?: string, options?: ErrorOptions): TypeError;
    new (message?: string): TypeError;
    (message?: string): TypeError;
    readonly prototype: TypeError;
}

declare var TypeError: TypeErrorConstructor;

interface URIError extends Error {}

interface URIErrorConstructor extends ErrorConstructor {
    new (message?: string, options?: ErrorOptions): URIError;
    (message?: string, options?: ErrorOptions): URIError;
    new (message?: string): URIError;
    (message?: string): URIError;
    readonly prototype: URIError;
}

declare var URIError: URIErrorConstructor;

// JSON

interface JSON {
    parse(text: string, reviver?: (key: string, value: any) => any): any;
    stringify(value: any, replacer?: (key: string, value: any) => any, space?: string | number): string;
    stringify(value: any, replacer?: (number | string)[] | null, space?: string | number): string;
}

declare var JSON: JSON;

// Console, which isn't in tsc's `lib.es2022.d.ts`; `tests/oracle/globals.d.ts` declares the same.

interface Console {
    assert(condition?: boolean, ...data: any[]): void;
    count(label?: string): void;
    countReset(label?: string): void;
    debug(...data: any[]): void;
    dir(item?: any, options?: any): void;
    error(...data: any[]): void;
    group(...data: any[]): void;
    groupCollapsed(...data: any[]): void;
    groupEnd(): void;
    info(...data: any[]): void;
    log(...data: any[]): void;
    warn(...data: any[]): void;
}

declare var console: Console;
