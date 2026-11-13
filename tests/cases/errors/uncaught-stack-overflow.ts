function down(n: number): number {
  return down(n + 1) + 1; //!! RangeError: Maximum call stack size exceeded
}
down(0);
