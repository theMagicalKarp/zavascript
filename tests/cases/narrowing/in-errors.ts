interface Fish { swim: () => string }
interface Bird { fly: () => string; legs?: number }
function wrong(animal: Fish | Bird) {
  if ("fly" in animal) {
    animal.swim; //! TS2339
  } else {
    animal.fly; //! TS2339
  }
}
