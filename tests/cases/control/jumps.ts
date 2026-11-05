break; //! TS1105
continue; //! TS1104
for (;;) {
  break nope; //! TS1116
}
lbl: {
  continue lbl; //! TS1115
}
for (;;) {
  continue nope; //! TS1115
}
