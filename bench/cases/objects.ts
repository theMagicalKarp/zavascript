// Object and array heavy code: literals, property reads and writes, destructuring and
// `for...of` over arrays.
interface Particle {
  x: number;
  y: number;
  vx: number;
  vy: number;
}

const particles: Particle[] = [];
for (let i = 0; i < 2000; i++) {
  particles[i] = { x: i % 37, y: i % 91, vx: (i % 5) - 2, vy: (i % 7) - 3 };
}
for (let step = 0; step < 20; step++) {
  for (const p of particles) {
    p.x += p.vx;
    p.y += p.vy;
    if (p.x < 0 || p.x > 100) p.vx = -p.vx;
    if (p.y < 0 || p.y > 100) p.vy = -p.vy;
  }
}
let sum = 0;
for (const { x, y } of particles) {
  sum += x + y;
}
console.log(sum);

const counts = { a: 0, b: 0, c: 0 };
for (let i = 0; i < 20000; i++) {
  const [first, second] = [i % 3, i % 5];
  if (first === 0) counts.a++;
  else if (second === 0) counts.b++;
  else counts.c++;
}
console.log(counts);

let merged = { total: 0, last: [0, 0] };
for (let i = 0; i < 2000; i++) {
  merged = { ...merged, total: merged.total + i, last: [merged.last[1], i] };
}
console.log(merged);
