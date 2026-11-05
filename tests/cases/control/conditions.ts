// The usual truthiness checks apply to every kind of condition.
if ("a") {} //! TS2872
while ("") {} //! TS2873
do {} while (null); //! TS2873
for (; 5; ) {} //! TS2872
if (!"a") {} //! TS2872
