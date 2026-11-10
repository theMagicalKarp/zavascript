const point = { x: 1, y: 2 };
point.z; //! TS2339
point.z = 3; //! TS2339
point.x = "1"; //! TS2322
point["x"] = true; //! TS2322
point["nope"]; //! TS7053
const key: string = "x";
point[key]; //! TS7053
point[true]; //! TS2538
console.log({ a: 1 } === { a: 1 }, [] !== []); //! TS2839 TS2839
const dup = { a: 1, a: 2 }; //! TS1117
const overwritten = { a: 1, ...point, x: 3 };
const spreadOver = { x: 0, ...point }; //! TS2783
const notObject = { ...1 }; //! TS2698
interface Fixed {
  readonly id: number;
  label?: string;
}
const fixed: Fixed = { id: 1 };
fixed.id = 2; //! TS2540
fixed.id++; //! TS2540
delete fixed.id; //! TS2704
delete fixed.label;
delete point.x; //! TS2790
delete point; //! TS1102 TS2703
"x" in 5; //! TS2322
true in point; //! TS2322
