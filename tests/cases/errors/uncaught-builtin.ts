// An error a builtin raises is reported from the line that called it.
const config = '{"a": 1,}';
JSON.parse(config); //!! SyntaxError: Expected double-quoted property name in JSON at position 8 (line 1 column 9)
