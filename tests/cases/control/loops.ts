let i = 0;
while (i < 3) {
  console.log("while", i);
  i++;
}
//> while 0
//> while 1
//> while 2
do {
  console.log("do", i);
} while (i < 3);
//> do 3
for (let j = 0; j < 3; j += 1) console.log("for", j);
//> for 0
//> for 1
//> for 2
let k = 0;
for (; k < 10; ) {
  k += 4;
}
console.log(k); //> 12
for (let a = 0, b = 10; a < b; a += 3, b -= 3) console.log(a, b);
//> 0 10
//> 3 7
let sum = 0;
for (let x = 1; x <= 100; x++) sum += x;
console.log(sum); //> 5050
