// Array pipelines, string building, Map and Set, and JSON: the builtins in the hot path.
const n = 20000;
const numbers = Array.from({ length: n }, (_, i) => (i * 7919) % 1000);
const evens = numbers.filter((x) => x % 2 === 0);
const squares = evens.map((x) => x * x);
const total = squares.reduce((a, b) => a + b, 0);
const sorted = [...numbers].sort((a, b) => a - b);
const counts = new Map<number, number>();
for (const x of numbers) {
  counts.set(x, (counts.get(x) ?? 0) + 1);
}
const unique = new Set(numbers);
const words: string[] = [];
for (let i = 0; i < 2000; i++) {
  words.push(`w${i % 97}`);
}
const sentence = words.join(" ");
const parts = sentence.split(" ").map((w) => w.toUpperCase());
const record: Record<string, number> = {};
for (const w of parts) {
  record[w] = (record[w] ?? 0) + 1;
}
const json = JSON.stringify({ sorted: sorted.slice(0, 100), record });
const parsed = JSON.parse(json);
console.log(total, sorted[n - 1], counts.size, unique.size, parts.length, Object.keys(parsed.record).length, Math.max(...sorted.slice(0, 1000)));
