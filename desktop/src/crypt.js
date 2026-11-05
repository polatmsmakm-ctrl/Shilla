// نفس تشفير نسخة الآيفون: AES-256-GCM، المفتاح = SHA256("shilla-v2|" + key)
// الشكل: nonce(12) + ciphertext + tag(16)  (نفس CryptoKit SealedBox.combined)
const crypto = require('crypto');
const S = require('./secrets.js');
const KEY = crypto.createHash('sha256').update('shilla-v2|' + S.key, 'utf8').digest();

function seal(obj) {
  const iv = crypto.randomBytes(12);
  const c = crypto.createCipheriv('aes-256-gcm', KEY, iv);
  const ct = Buffer.concat([c.update(Buffer.from(JSON.stringify(obj), 'utf8')), c.final()]);
  return Buffer.concat([iv, ct, c.getAuthTag()]);
}

function open(buf) {
  try {
    const b = Buffer.from(buf);
    if (b.length < 29) return null;
    const d = crypto.createDecipheriv('aes-256-gcm', KEY, b.subarray(0, 12));
    d.setAuthTag(b.subarray(b.length - 16));
    const plain = Buffer.concat([d.update(b.subarray(12, b.length - 16)), d.final()]);
    return JSON.parse(plain.toString('utf8'));
  } catch (_) {
    return null;
  }
}

function fingerprint(buf) {
  return crypto.createHash('sha256').update(Buffer.from(buf)).digest('base64');
}

module.exports = { seal, open, fingerprint, ns: S.ns };
