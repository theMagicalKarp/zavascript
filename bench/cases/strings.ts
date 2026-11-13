// Walking long strings a code unit at a time, which shouldn't rescan the string on each access.
const ascii = "abcdefghij".repeat(5000);
const accented = "àéîõü".repeat(10000);
let sum = 0;
for (let i = 0; i < ascii.length; i++) {
  sum += ascii.charCodeAt(i);
}
for (let i = 0; i < accented.length; i++) {
  sum += accented.charCodeAt(i) + accented[i].length + accented.charAt(i).length;
}
console.log(sum);
