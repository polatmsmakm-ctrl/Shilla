// النقل المباشر — نفس بروتوكول نسخة الآيفون بالضبط:
// 4 «حارات» = 4 اتصالات WebRTC مستقلة لكل صديق، كل ملف ينقسم عليها.
// القطعة: [8 بايت مكان القطعة big-endian][البيانات] بحد 256KB.
const fs = require('fs');
const path = require('path');

const LANES = 4;
const CHUNK = 262136;
const MAX_BUFFERED = 6000000;
const READ_BLOCK = 4 << 20;

function iceServers() {
  const s = [{ urls: ['stun:stun.l.google.com:19302', 'stun:stun1.l.google.com:19302', 'stun:stun.cloudflare.com:3478'] }];
  const t = localStorage.getItem('turnURL');
  if (t) s.push({ urls: [t], username: localStorage.getItem('turnUser') || '', credential: localStorage.getItem('turnPass') || '' });
  return s;
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
class Closed extends Error { constructor() { super('closed'); } }

// ===================== الاتصال مع صديق =====================

class PeerLink {
  constructor({ peer, initiator, lid, sendSignal, makeIncoming }) {
    this.peer = peer;
    this.initiator = initiator;
    this.lid = lid;
    this.created = Date.now();
    this.sendSignal = sendSignal;
    this.makeIncoming = makeIncoming;
    this.state = 'connecting';
    this.isConnected = false;
    this.onState = null;
    this.onLanes = null;
    this.pcs = [];
    this.remoteSet = Array(LANES).fill(false);
    this.pending = Array.from({ length: LANES }, () => []);
    this.laneUp = Array(LANES).fill(false);
    this.outs = new Set();
    this.ins = new Map();
    this.closed = false;

    for (let i = 0; i < LANES; i++) {
      const pc = new RTCPeerConnection({ iceServers: iceServers(), bundlePolicy: 'max-bundle', rtcpMuxPolicy: 'require' });
      pc.onicecandidate = (e) => {
        if (!e.candidate || !e.candidate.candidate) return;
        this.sendSignal({ t: 'ice', candidate: e.candidate.candidate, mline: e.candidate.sdpMLineIndex || 0,
          mid: e.candidate.sdpMid || '', ln: i, lid: this.lid });
      };
      pc.oniceconnectionstatechange = () => this.laneState(i, pc.iceConnectionState);
      pc.ondatachannel = (e) => this.onChannel(e.channel);
      this.pcs.push(pc);
    }
  }

  get hasRemote() { return this.remoteSet.some(Boolean); }
  get lanesUp() { return this.laneUp.filter(Boolean).length; }

  async makeOffer() {
    this.pcs.forEach(async (pc, i) => {
      try {
        pc.createDataChannel('ctl');
        const offer = await pc.createOffer();
        await pc.setLocalDescription(offer);
        this.sendSignal({ t: 'offer', sdp: offer.sdp, ln: i, lid: this.lid, lts: this.created / 1000 });
      } catch (_) {}
    });
  }

  async handleOffer(i, sdp) {
    const pc = this.pcs[i];
    if (!pc) return;
    try {
      await pc.setRemoteDescription({ type: 'offer', sdp });
      this.markRemote(i);
      const ans = await pc.createAnswer();
      await pc.setLocalDescription(ans);
      this.sendSignal({ t: 'answer', sdp: ans.sdp, ln: i, lid: this.lid });
    } catch (_) {}
  }

  async handleAnswer(i, sdp) {
    const pc = this.pcs[i];
    if (!pc) return;
    try {
      await pc.setRemoteDescription({ type: 'answer', sdp });
      this.markRemote(i);
    } catch (_) {}
  }

  handleIce(i, m) {
    const pc = this.pcs[i];
    if (!pc || typeof m.candidate !== 'string') return;
    const c = { candidate: m.candidate, sdpMLineIndex: Number(m.mline) || 0, sdpMid: m.mid ? m.mid : '0' };
    if (this.remoteSet[i]) pc.addIceCandidate(c).catch(() => {});
    else this.pending[i].push(c);
  }

  markRemote(i) {
    this.remoteSet[i] = true;
    const p = this.pending[i];
    this.pending[i] = [];
    p.forEach((c) => this.pcs[i].addIceCandidate(c).catch(() => {}));
  }

  abortAll() {
    this.outs.forEach((o) => o.abort());
    [...this.ins.values()].forEach((x) => x.abort());
  }

  laneState(i, st) {
    const up = st === 'connected' || st === 'completed';
    this.laneUp[i] = up;
    if (this.onLanes) this.onLanes(this.lanesUp);
    if (i !== 0 && (st === 'failed' || st === 'closed')) this.abortAll();
    if (i !== 0) return;
    let s = 'connecting';
    if (up) s = 'connected';
    else if (st === 'disconnected') s = 'weak';
    else if (st === 'failed') s = 'failed';
    else if (st === 'closed') s = 'closed';
    this.state = s;
    this.isConnected = s === 'connected';
    if (s === 'failed' || s === 'closed') this.abortAll();
    if (this.onState) this.onState(s);
  }

  onChannel(dc) {
    const parts = dc.label.split(':');
    if (parts.length !== 3 || parts[0] !== 'f') return;
    const tid = parts[1];
    dc.binaryType = 'arraybuffer';
    let inc = this.ins.get(tid);
    if (!inc) {
      inc = this.makeIncoming(tid);
      inc.onClosed = () => this.ins.delete(tid);
      this.ins.set(tid, inc);
    }
    inc.attach(dc);
  }

  async sendFile(meta, filePath, size, onProgress) {
    const tid = cryptoRandomUUID();
    const dcs = [];
    const lanesUsed = [];
    this.pcs.forEach((pc, i) => {
      if (i !== 0 && !this.laneUp[i]) return;
      try {
        const dc = pc.createDataChannel(`f:${tid}:${i}`, { ordered: false });
        dc.binaryType = 'arraybuffer';
        dcs.push(dc);
        lanesUsed.push(i);
      } catch (e) {
        if (i === 0) throw new Closed();
      }
    });
    if (!dcs.length) throw new Closed();
    const out = new OutgoingFile(dcs, (k) => lanesUsed[k] === 0 || this.laneUp[lanesUsed[k]]);
    out.bid = meta.bid;
    this.outs.add(out);
    try {
      await out.run({ ...meta, tid }, filePath, size, onProgress);
    } finally {
      this.outs.delete(out);
      dcs.forEach((d) => { try { d.close(); } catch (_) {} });
    }
  }

  close() {
    this.closed = true;
    this.abortAll();
    this.pcs.forEach((pc) => { try { pc.close(); } catch (_) {} });
  }
}

function cryptoRandomUUID() {
  return require('crypto').randomUUID().toUpperCase();
}

// ===================== المُرسِل لملف واحد =====================

class OutgoingFile {
  constructor(dcs, laneOK) {
    this.dcs = dcs;
    this.laneOK = laneOK;
    this.events = [];
    this.waiter = null;
    this.dead = false;
    dcs.forEach((dc, k) => {
      dc.bufferedAmountLowThreshold = 1 << 20;
      dc.onopen = () => { if (k === 0) this.push({ t: 'open' }); };
      dc.onclose = () => this.push({ t: 'closed' });
      dc.onerror = () => this.push({ t: 'closed' });
      dc.onbufferedamountlow = () => this.wake();
      if (k === 0) dc.onmessage = (e) => { if (typeof e.data === 'string') this.push({ t: 'text', s: e.data }); };
    });
  }

  get ctl() { return this.dcs[0]; }

  push(ev) {
    if (ev.t === 'closed') this.dead = true;
    this.events.push(ev);
    this.wake();
  }

  wake() {
    const w = this.waiter;
    this.waiter = null;
    if (w) w();
  }

  abort() { this.push({ t: 'closed' }); }

  async next() {
    while (!this.events.length) await new Promise((r) => { this.waiter = r; });
    return this.events.shift();
  }

  async run(meta, filePath, size, onProgress) {
    if (this.ctl.readyState !== 'open') {
      for (;;) {
        const ev = await this.next();
        if (ev.t === 'open') break;
        if (ev.t === 'closed') throw new Closed();
      }
    }
    this.ctl.send(JSON.stringify(meta));

    let offset = null;
    for (;;) {
      const ev = await this.next();
      if (ev.t === 'closed') throw new Closed();
      if (ev.t === 'text') {
        try {
          const j = JSON.parse(ev.s);
          if (typeof j.offset === 'number') { offset = j.offset; break; }
        } catch (_) {}
      }
    }

    if (offset < size) await this.pump(filePath, offset, size, onProgress);

    // ننتظر التأكيد، ولو ما تحرك شي 45 ثانية نعيد المحاولة
    let last = -1, idle = 0;
    const wd = setInterval(() => {
      const b = this.totalBuffered();
      if (b !== last) { last = b; idle = 0; } else idle += 3;
      if (idle >= 45) this.abort();
    }, 3000);
    try {
      for (;;) {
        const ev = await this.next();
        if (ev.t === 'closed') throw new Closed();
        if (ev.t === 'text' && ev.s.includes('"ok"')) break;
      }
    } finally {
      clearInterval(wd);
    }
    onProgress(size);
  }

  totalBuffered() { return this.dcs.reduce((a, d) => a + (d.readyState === 'open' ? d.bufferedAmount : 0), 0); }

  pickChannel() {
    let best = null, bestBuf = Infinity;
    this.dcs.forEach((d, k) => {
      if (d.readyState !== 'open' || !this.laneOK(k)) return;
      if (d.bufferedAmount < bestBuf) { best = d; bestBuf = d.bufferedAmount; }
    });
    return best && bestBuf < MAX_BUFFERED ? best : null;
  }

  async pump(filePath, offset, size, onProgress) {
    const fd = fs.openSync(filePath, 'r');
    try {
      let sent = offset;
      let lastReport = 0;
      const block = Buffer.allocUnsafe(READ_BLOCK);
      while (sent < size) {
        if (this.dead || this.ctl.readyState !== 'open') throw new Closed();
        const n = fs.readSync(fd, block, 0, Math.min(READ_BLOCK, size - sent), sent);
        if (n <= 0) break;
        for (let i = 0; i < n; i += CHUNK) {
          const len = Math.min(CHUNK, n - i);
          const frame = new Uint8Array(8 + len);
          new DataView(frame.buffer).setBigUint64(0, BigInt(sent + i), false);
          frame.set(block.subarray(i, i + len), 8);
          for (;;) {
            if (this.dead || this.ctl.readyState !== 'open') throw new Closed();
            const ch = this.pickChannel();
            if (ch) {
              try { ch.send(frame); } catch (_) { throw new Closed(); }
              break;
            }
            await Promise.race([new Promise((r) => { this.waiter = r; }), sleep(20)]);
          }
        }
        sent += n;
        const now = Date.now();
        if (now - lastReport > 120) {
          lastReport = now;
          onProgress(Math.max(0, sent - this.totalBuffered()));
        }
      }
    } finally {
      fs.closeSync(fd);
    }
  }
}

// ===================== المستقبِل لملف واحد =====================

const BAD = /[<>:"\\|?*\x00-\x1f]/g;

class IncomingFile {
  constructor(tid, from, ev, receivedDir) {
    this.tid = tid;
    this.from = from;
    this.ev = ev;
    this.receivedDir = receivedDir;
    this.chans = [];
    this.onClosed = null;
    this.meta = null;
    this.ctl = null;
    this.fd = null;
    this.wm = 0;
    this.lastPersisted = 0;
    this.startOffset = 0;
    this.gotBytes = 0;
    this.pendingChunks = new Map();
    this.finished = false;
    this.lastReport = 0;
  }

  attach(dc) {
    this.chans.push(dc);
    dc.onmessage = (e) => {
      if (typeof e.data === 'string') this.onText(e.data, dc);
      else this.onBinary(new Uint8Array(e.data));
    };
    dc.onclose = () => { if (!this.finished) this.fail(); };
  }

  abort() { this.fail(); }

  persistWatermark() {
    if (!this.wmPath) return;
    try { fs.writeFileSync(this.wmPath, String(this.wm)); } catch (_) {}
    this.lastPersisted = this.wm;
  }

  fail() {
    if (this.finished) return;
    this.finished = true;
    if (this.meta) this.persistWatermark();
    if (this.fd !== null) { try { fs.closeSync(this.fd); } catch (_) {} this.fd = null; }
    // نسكّر كل القنوات حتى المُرسِل يدري ويعيد من علامة التقدّم
    this.chans.forEach((c) => { try { c.close(); } catch (_) {} });
    if (this.meta) this.ev.onFail(this.meta, this.from);
    if (this.onClosed) this.onClosed();
  }

  reply(obj) {
    try { if (this.ctl && this.ctl.readyState === 'open') this.ctl.send(JSON.stringify(obj)); } catch (_) {}
  }

  onText(s, dc) {
    if (this.meta) return;
    let m;
    try { m = JSON.parse(s); } catch (_) { return; }
    if (typeof m.bid !== 'string' || typeof m.bname !== 'string' || typeof m.rel !== 'string') return;
    m.size = Number(m.size) || 0;
    m.bsize = Number(m.bsize) || 0;
    m.bcount = Number(m.bcount) || 1;
    m.folder = !!m.folder;
    m.kind = m.kind || 'file';
    this.meta = m;
    this.ctl = dc;

    const comps = m.rel.split('/').map((c) => c.replace(BAD, '_').trim()).filter((c) => c && c !== '.' && c !== '..');
    if (!comps.length) { this.fail(); return; }
    let dest = path.join(this.receivedDir, ...comps);
    fs.mkdirSync(path.dirname(dest), { recursive: true });
    this.top = comps[0];

    if (fs.existsSync(dest)) {
      let existing = -1;
      try { existing = fs.statSync(dest).size; } catch (_) {}
      if (existing === m.size) {
        this.finalPath = dest;
        this.ev.onStart(m, this.from);
        this.reply({ offset: m.size });
        this.complete(true);
        return;
      }
      dest = uniquePath(dest);
      if (comps.length === 1) this.top = path.basename(dest);
    }
    this.finalPath = dest;
    this.partPath = dest + '.part';
    this.wmPath = dest + '.wm';

    let offset = 0;
    if (fs.existsSync(this.partPath)) {
      try {
        const v = parseInt(fs.readFileSync(this.wmPath, 'utf8').trim(), 10);
        const psize = fs.statSync(this.partPath).size;
        if (v >= 0 && v <= m.size && v <= psize) offset = v;
      } catch (_) {}
    }
    try {
      this.fd = fs.openSync(this.partPath, fs.existsSync(this.partPath) ? 'r+' : 'w+');
    } catch (_) { this.fail(); return; }
    this.startOffset = offset;
    this.wm = offset;
    this.lastPersisted = offset;
    this.ev.onStart(m, this.from);
    this.ev.onProgress(m, this.from, offset);
    this.reply({ offset });
    if (this.wm >= m.size) this.complete(false);
  }

  advance(off, len) {
    if (off === this.wm) {
      this.wm += len;
      while (this.pendingChunks.has(this.wm)) {
        const l = this.pendingChunks.get(this.wm);
        this.pendingChunks.delete(this.wm);
        this.wm += l;
      }
    } else if (off > this.wm) {
      this.pendingChunks.set(off, len);
    }
  }

  onBinary(data) {
    const m = this.meta;
    if (!m || this.fd === null || this.finished || data.length <= 8) return;
    const off = Number(new DataView(data.buffer, data.byteOffset, 8).getBigUint64(0, false));
    const payload = data.subarray(8);
    try {
      fs.writeSync(this.fd, payload, 0, payload.length, off);
    } catch (_) { this.fail(); return; }
    this.gotBytes += payload.length;
    this.advance(off, payload.length);
    if (this.wm >= m.size) {
      this.ev.onProgress(m, this.from, m.size);
      this.complete(false);
      return;
    }
    if (this.wm - this.lastPersisted >= 32 * 1024 * 1024) this.persistWatermark();
    const now = Date.now();
    if (now - this.lastReport > 150) {
      this.lastReport = now;
      this.ev.onProgress(m, this.from, Math.min(m.size, this.startOffset + this.gotBytes));
    }
  }

  complete(alreadyThere) {
    const m = this.meta;
    if (!m || this.finished) return;
    this.finished = true;
    if (this.fd !== null) {
      try { if (!alreadyThere) fs.ftruncateSync(this.fd, m.size); } catch (_) {}
      try { fs.closeSync(this.fd); } catch (_) {}
      this.fd = null;
    }
    if (!alreadyThere) {
      try { fs.rmSync(this.finalPath, { force: true }); } catch (_) {}
      try { fs.renameSync(this.partPath, this.finalPath); } catch (_) {}
      try { fs.rmSync(this.wmPath, { force: true }); } catch (_) {}
    }
    this.reply({ ok: 1 });
    this.ev.onFinish(m, this.from, this.top);
    if (this.onClosed) this.onClosed();
  }
}

function uniquePath(p) {
  const dir = path.dirname(p);
  const ext = path.extname(p);
  const base = path.basename(p, ext);
  for (let n = 2; ; n++) {
    const c = path.join(dir, `${base} (${n})${ext}`);
    if (!fs.existsSync(c)) return c;
  }
}

module.exports = { PeerLink, IncomingFile, LANES, CHUNK, Closed, uniquePath };
