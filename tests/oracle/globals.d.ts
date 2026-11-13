// Globals zavascript provides that `lib.es2022` doesn't declare, so tsc can check the cases.
// Keep this in step with `Console` in `src/lib/lib.d.ts`.

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
