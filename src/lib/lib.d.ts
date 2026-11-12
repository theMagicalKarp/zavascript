// Declarations for the builtins, which the checker reads like any `.d.ts` file. For now that's
// the utility types; `T[]`, `Array<T>` and `ReadonlyArray<T>` are built into the checker until the
// array methods are declared here.

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
