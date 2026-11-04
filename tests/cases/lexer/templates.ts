// Template literals, including nested ones and braces inside substitutions.
console.log(`plain`); //> plain
console.log(`a${1 + 1}b${"c"}d`); //> a2bcd
console.log(`${"x"}${"y"}`); //> xy
console.log(`nested ${`inner ${1 + 2}`} done`); //> nested inner 3 done
console.log(`${null} ${undefined} ${true} ${0.5}`); //> null undefined true 0.5
console.log(`\${not a substitution} \``); //> ${not a substitution} `
console.log(`multi
line`);
//> multi
//> line
