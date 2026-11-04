// Globals zavascript provides that `lib.es2022` doesn't declare, so tsc can check the cases.
// Keep this in step with the runtime's builtins.

interface Console {
  log(...data: any[]): void;
  error(...data: any[]): void;
  warn(...data: any[]): void;
  info(...data: any[]): void;
  debug(...data: any[]): void;
}

declare var console: Console;
