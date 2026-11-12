interface Node { value: number; next?: Node }
function f(n: Node | undefined) {
  n.value; //! TS18048
  n?.next.value; //! TS18048
  const v: number = n?.value; //! TS2322
  n?.value + 1; //! TS18048
  n?.missing; //! TS2339
  n?.value = 1; //! TS2779
  n?.value++; //! TS18048 TS2777
  n?.next++; //! TS2356 TS18048
}
const u: unknown = 1;
u?.x; //! TS2339
