interface Fish { swim: () => string }
interface Bird { fly: () => string; legs?: number }
function move(animal: Fish | Bird) {
  if ("swim" in animal) {
    return animal.swim();
  }
  return animal.fly();
}
console.log(move({ swim: () => "swims" }), move({ fly: () => "flies" })); //> swims flies
// An optional property can be there or not.
function legs(animal: Fish | Bird) {
  if ("legs" in animal) {
    const bird: Bird = animal;
    return bird.legs;
  }
  return animal;
}
console.log(legs({ fly: () => "", legs: 2 })); //> 2
