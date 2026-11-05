// يقرأ المفاتيح من نسخة الآيفون حتى النسختين يتفاهمون (نفس التشفير ونفس المساحة)
const fs = require('fs');
const path = require('path');
const src = fs.readFileSync(path.join(__dirname, '..', 'Shilla', 'Secrets.swift'), 'utf8');
const get = (n) => {
  const m = src.match(new RegExp('static let ' + n + '\\s*=\\s*"([^"]*)"'));
  if (!m) throw new Error('missing ' + n + ' in Secrets.swift');
  return m[1];
};
const out = 'module.exports = ' + JSON.stringify({ ns: get('ns'), key: get('key') }) + ';\n';
fs.writeFileSync(path.join(__dirname, 'src', 'secrets.js'), out);
console.log('secrets.js generated');
