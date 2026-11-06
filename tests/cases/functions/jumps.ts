while (true) {
  function f() {
    break; //! TS1107
  }
  const g = () => {
    for (;;) {
      continue;
    }
  };
  break;
}
