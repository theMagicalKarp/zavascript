// Loops, branches and variable access: mostly measures the interpreter.
let total = 0;
for (let i = 0; i < 200000; i++) {
  if (i % 3 === 0) {
    total += i;
  } else if (i % 5 === 0) {
    total -= i >> 1;
  } else {
    total ^= i;
  }
}
console.log(total);

// Collatz steps for the first few thousand numbers.
let longest = 0;
let longestStart = 0;
for (let start = 1; start < 3000; start++) {
  let n = start;
  let steps = 0;
  while (n !== 1) {
    n = n % 2 === 0 ? n / 2 : 3 * n + 1;
    steps++;
  }
  if (steps > longest) {
    longest = steps;
    longestStart = start;
  }
}
console.log(longestStart, longest);

// Primes by trial division, with labeled `continue`.
let primes = 0;
candidates: for (let c = 2; c < 20000; c++) {
  for (let d = 2; d * d <= c; d++) {
    if (c % d === 0) {
      continue candidates;
    }
  }
  primes++;
}
console.log(primes);

let digits = "";
let k = 0;
do {
  switch (k % 4) {
    case 0:
      digits += "a";
      break;
    case 1:
      digits += k;
      break;
    default:
      digits += "-";
  }
  k++;
} while (k < 2000);
console.log(digits === "");
