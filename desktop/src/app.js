// حالة البرنامج ومنطقه — نفس منطق AppState في نسخة الآيفون.
const fs = require('fs');
const os = require('os');
const path = require('path');
const crypt = require('./crypt.js');
const { MQTTClient } = require('./mqtt.js');
const { PeerLink, IncomingFile } = require('./peer.js');

const SIGNALS = ['offer', 'answer', 'ice', 'want'];
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const uuid = () => require('crypto').randomUUID().toUpperCase();
const now = () => Date.now() / 1000;

function load(k, d) {
  try { const v = localStorage.getItem(k); return v === null ? d : JSON.parse(v); } catch (_) { return d; }
}
function save(k, v) { try { localStorage.setItem(k, JSON.stringify(v)); } catch (_) {} }

function kindOf(name) {
  const e = path.extname(name).slice(1).toLowerCase();
  if (['mov', 'mp4', 'm4v', 'hevc', 'avi', 'mkv', '3gp', 'webm'].includes(e)) return 'video';
  if (['jpg', 'jpeg', 'png', 'heic', 'heif', 'gif', 'webp', 'dng', 'tiff', 'bmp'].includes(e)) return 'image';
  return 'file';
}

function listFiles(p) {
  const st = fs.statSync(p);
  if (!st.isDirectory()) return { isFolder: false, files: [{ path: p, rel: path.basename(p), size: st.size }] };
  const root = path.basename(p);
  const files = [];
  const walk = (dir, relDir) => {
    for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
      if (e.name.startsWith('.')) continue;
      const full = path.join(dir, e.name);
      const rel = relDir + '/' + e.name;
      if (e.isDirectory()) walk(full, rel);
      else if (e.isFile()) files.push({ path: full, rel, size: fs.statSync(full).size });
    }
  };
  walk(p, root);
  return { isFolder: true, files };
}

class App extends EventTarget {
  constructor() {
    super();
    this.deviceId = load('did', null) || uuid().slice(0, 8).toLowerCase();
    save('did', this.deviceId);
    this.username = load('username', '');
    this.friends = load('friends', []);
    this.messages = load('messages', []);
    this.lastRead = load('lastRead', {});
    for (const m of this.messages) if (m.status === 'active') m.status = 'failed';

    this.progress = {};
    this.online = {};
    this.linkStates = {};
    this.lanes = {};
    this.links = {};
    this.brokersUp = new Set();
    this.presenceBy = {};
    this.seen = new Set();
    this.seenOrder = [];
    this.retiredLids = new Set();
    this.linkTs = {};
    this.earlyIce = {};
    this.lastRequest = {};
    this.sendTasks = {};
    this.cancelled = new Set();
    this.recvBase = {};
    this.recvCount = {};
    this.recvLive = {};
    this.recvDone = {};
    this.lastSample = {};
    this.activeChat = null;
    this.locked = true;

    this.receivedDir = path.join(os.homedir(), 'Downloads', 'JellyJump');
    fs.mkdirSync(this.receivedDir, { recursive: true });

    this.mqtt = new MQTTClient({
      onState: (b, up) => this.brokerState(b, up),
      onConnected: (b) => this.mqttConnected(b),
      onMessage: (t, d, b) => this.mqttMessage(t, d, b),
    });
    this.changeTimer = null;
  }

  changed() {
    if (this.changeTimer) return;
    this.changeTimer = setTimeout(() => {
      this.changeTimer = null;
      this.dispatchEvent(new Event('change'));
    }, 60);
  }

  toast(s) { this.dispatchEvent(Object.assign(new Event('toast'), { text: s })); }

  get isSetup() { return !!this.username; }
  get mqttUp() { return this.brokersUp.size > 0; }

  // ---------- الحساب والسيرفر ----------

  register(name) {
    const n = (name || '').toLowerCase().trim();
    if (!/^[a-z0-9_]{3,20}$/.test(n)) return false;
    this.username = n;
    save('username', n);
    this.start();
    return true;
  }

  inbox(u) { return `shilla/${crypt.ns}/u/${u}`; }
  get presencePrefix() { return `shilla/${crypt.ns}/p/`; }
  presence(u) { return this.presencePrefix + u; }

  start() {
    if (!this.isSetup || this.started) return;
    this.started = true;
    this.mqtt.connect(`shilla-${crypt.ns.slice(0, 6)}-${this.username}-${this.deviceId}`,
      this.presence(this.username), Buffer.from('0'));
    window.addEventListener('beforeunload', () => {
      this.mqtt.publish(this.presence(this.username), Buffer.from('0'), { retain: true, queue: false });
    });
  }

  brokerState(b, up) {
    if (up) this.brokersUp.add(b);
    else {
      this.brokersUp.delete(b);
      for (const u of Object.keys(this.presenceBy)) { delete this.presenceBy[u][b]; this.recomputePresence(u); }
    }
    this.changed();
  }

  mqttConnected(b) {
    this.mqtt.subscribe(this.inbox(this.username));
    for (const f of this.friends) this.mqtt.subscribe(this.presence(f.id));
    this.mqtt.publish(this.presence(this.username), Buffer.from('1'), { retain: true, only: b });
  }

  mqttMessage(topic, data, b) {
    if (topic.startsWith(this.presencePrefix)) {
      const u = topic.slice(this.presencePrefix.length);
      if (u === this.username) return;
      (this.presenceBy[u] = this.presenceBy[u] || {})[b] = data.toString() === '1';
      this.recomputePresence(u);
      return;
    }
    if (topic !== this.inbox(this.username)) return;
    const fp = crypt.fingerprint(data);
    if (this.seen.has(fp)) return;
    this.seen.add(fp);
    this.seenOrder.push(fp);
    if (this.seenOrder.length > 2000) this.seen.delete(this.seenOrder.shift());
    const d = crypt.open(data);
    if (!d || typeof d.t !== 'string' || typeof d.from !== 'string') return;
    const from = d.from.toLowerCase();
    if (from === this.username) return;
    this.handleInbox(d.t, from, d);
  }

  sendTo(peer, dict) {
    const d = { ...dict, from: this.username, sent: now() };
    const sealed = crypt.seal(d);
    this.mqtt.publish(this.inbox(peer), sealed, { queue: !SIGNALS.includes(dict.t) });
  }

  recomputePresence(u) {
    const on = Object.values(this.presenceBy[u] || {}).some(Boolean);
    if (!!this.online[u] !== on) this.presenceChanged(u, on);
  }

  presenceChanged(u, on) {
    this.online[u] = on;
    if (on) {
      this.ensureLink(u);
      this.autoResume(u);
    } else {
      if (this.links[u]) { this.retiredLids.add(this.links[u].lid); this.links[u].close(); }
      delete this.links[u];
      delete this.linkStates[u];
      delete this.lanes[u];
    }
    this.changed();
  }

  // ---------- الرسائل الواردة ----------

  handleInbox(t, from, d) {
    if (SIGNALS.includes(t) && typeof d.sent === 'number' && now() - d.sent > 600) return;
    switch (t) {
      case 'chat': {
        if (typeof d.id !== 'string' || typeof d.text !== 'string') return;
        this.addFriendIfNeeded(from);
        this.sendTo(from, { t: 'ack', id: d.id });
        const m = { id: d.id, peer: from, ts: typeof d.ts === 'number' ? d.ts : now(), text: d.text, outgoing: false };
        if (this.appendMessage(m)) {
          if (this.activeChat === from) this.markRead(from);
          this.notify();
        }
        break;
      }
      case 'ack': {
        const m = this.messages.find((x) => x.id === d.id);
        if (m) { m.delivered = true; this.saveMessages(); this.changed(); }
        break;
      }
      case 'offer': {
        if (typeof d.sdp !== 'string') return;
        const lid = d.lid || '';
        const ln = Number(d.ln) || 0;
        const lts = Number(d.lts) || 0;
        this.addFriendIfNeeded(from);
        const cur = this.links[from];
        if (cur && cur.lid === lid && !cur.initiator) { cur.handleOffer(ln, d.sdp); return; }
        if (this.retiredLids.has(lid)) return;
        if (this.linkTs[from] && lts > 0 && lts < this.linkTs[from]) return;
        if (cur && cur.initiator && !cur.hasRemote && this.username > from) return;
        this.makeLink(from, false, lid);
        if (lts > 0) this.linkTs[from] = lts;
        this.links[from].handleOffer(ln, d.sdp);
        const early = this.earlyIce[lid];
        delete this.earlyIce[lid];
        if (early) early.forEach(([eln, ed]) => this.links[from] && this.links[from].handleIce(eln, ed));
        break;
      }
      case 'answer': {
        const l = this.links[from];
        if (typeof d.sdp === 'string' && l && l.lid === (d.lid || '')) l.handleAnswer(Number(d.ln) || 0, d.sdp);
        break;
      }
      case 'ice': {
        const lid = d.lid || '';
        const ln = Number(d.ln) || 0;
        const l = this.links[from];
        if (l && l.lid === lid) l.handleIce(ln, d);
        else if (lid && !this.retiredLids.has(lid)) {
          if (Object.keys(this.earlyIce).length > 8) this.earlyIce = {};
          (this.earlyIce[lid] = this.earlyIce[lid] || []).push([ln, d]);
        }
        break;
      }
      case 'cancel': {
        const m = this.messages.find((x) => x.id === d.bid);
        if (!m || m.peer !== from) return;
        this.cancelled.add(d.bid);
        if (this.sendTasks[d.bid]) this.sendTasks[d.bid].cancel = true;
        // نوقف الملف اللي ينرسل الحين فوراً
        const cl = this.links[from];
        if (cl) cl.outs.forEach((o) => { if (o.bid === d.bid) o.abort(); });
        const p = this.progress[d.bid];
        if (p ? !p.finished : m.status === 'active') {
          this.finish(d.bid, false, `ألغاه @${from}`, true);
          this.markCancelled(d.bid);
        }
        break;
      }
      case 'want': {
        this.addFriendIfNeeded(from);
        const l = this.links[from];
        if (l && l.initiator && (l.isConnected || (l.state === 'connecting' && Date.now() - l.created < 10000))) return;
        this.makeLink(from, true);
        break;
      }
      case 'cloud':
        // الإرسال عبر الوسيط السحابي غير مدعوم بنسخة الكمبيوتر
        break;
      default: break;
    }
  }

  // ---------- الأصدقاء ----------

  addFriend(name) {
    const n = (name || '').toLowerCase().replace(/[@\s]/g, '');
    if (!/^[a-z0-9_]{3,20}$/.test(n) || n === this.username) return false;
    this.addFriendIfNeeded(n);
    return true;
  }

  addFriendIfNeeded(u) {
    if (this.friends.some((f) => f.id === u)) return;
    this.friends.push({ id: u, addedAt: now() });
    save('friends', this.friends);
    this.mqtt.subscribe(this.presence(u));
    this.changed();
  }

  removeFriend(u) {
    this.friends = this.friends.filter((f) => f.id !== u);
    if (this.links[u]) this.links[u].close();
    delete this.links[u];
    save('friends', this.friends);
    this.changed();
  }

  // ---------- الاتصال المباشر ----------

  ensureLink(u) {
    if (!this.friends.some((f) => f.id === u)) return;
    const l = this.links[u];
    if (l && l.state !== 'failed' && l.state !== 'closed') return;
    if (this.username > u) this.makeLink(u, true);
  }

  makeLink(u, initiator, lid = uuid()) {
    const old = this.links[u];
    if (old) {
      this.retiredLids.add(old.lid);
      if (this.retiredLids.size > 200) this.retiredLids.clear();
      old.close();
    }
    if (initiator) delete this.linkTs[u];
    const link = new PeerLink({
      peer: u, initiator, lid,
      sendSignal: (d) => this.sendTo(u, d),
      makeIncoming: (tid) => new IncomingFile(tid, u, this.recvEvents(), this.receivedDir),
    });
    link.onState = (st) => this.linkState(u, link, st);
    link.onLanes = (n) => { if (this.links[u] === link) { this.lanes[u] = n; this.changed(); } };
    this.links[u] = link;
    this.linkStates[u] = 'connecting';
    this.lanes[u] = 0;
    if (initiator) link.makeOffer();
    this.changed();
  }

  linkState(u, link, st) {
    if (this.links[u] !== link) return;
    this.linkStates[u] = st;
    this.changed();
    if (st === 'failed') {
      setTimeout(() => {
        if (this.links[u] === link && this.linkStates[u] === 'failed' && this.online[u]) this.requestConnection(u);
      }, 3000);
    }
  }

  requestConnection(u) {
    if (this.username > u) this.makeLink(u, true);
    else this.sendTo(u, { t: 'want' });
  }

  isDirect(u) { return this.linkStates[u] === 'connected'; }

  async waitConnected(peer, timeout, task) {
    const deadline = Date.now() + timeout * 1000;
    while (Date.now() < deadline && !task.cancel) {
      const l = this.links[peer];
      if (l && l.isConnected) return true;
      const stuck = l && l.state === 'connecting' && Date.now() - l.created > 25000;
      const dead = !l || l.state === 'failed' || l.state === 'closed' || stuck;
      const recent = this.lastRequest[peer] && Date.now() - this.lastRequest[peer] < 8000;
      if (dead && !recent && this.online[peer]) {
        this.lastRequest[peer] = Date.now();
        this.requestConnection(peer);
      }
      await sleep(300);
    }
    return !!(this.links[peer] && this.links[peer].isConnected);
  }

  async waitOnline(peer, bid, task) {
    if (this.online[peer]) return;
    this.setNote(bid, `بانتظار دخول @${peer}…`);
    while (!this.online[peer] && !task.cancel) await sleep(1000);
    this.setNote(bid, '');
  }

  // ---------- الدردشة ----------

  chat(peer) { return this.messages.filter((m) => m.peer === peer); }
  last(peer) { const c = this.chat(peer); return c[c.length - 1]; }
  unread(peer) {
    const lr = this.lastRead[peer] || 0;
    return this.messages.filter((m) => m.peer === peer && !m.outgoing && m.ts > lr).length;
  }
  get totalUnread() { return this.friends.reduce((a, f) => a + this.unread(f.id), 0); }
  markRead(peer) {
    if (this.locked) return;
    const l = this.last(peer);
    if (!l) return;
    if ((this.lastRead[peer] || 0) >= l.ts) return;
    this.lastRead[peer] = l.ts;
    save('lastRead', this.lastRead);
    this.changed();
  }

  sendText(t, peer) {
    const text = (t || '').trim();
    if (!text) return;
    const m = { id: uuid(), peer, ts: now(), text, outgoing: true, delivered: false };
    this.appendMessage(m);
    this.sendTo(peer, { t: 'chat', id: m.id, text, ts: m.ts });
  }

  appendMessage(m) {
    if (this.messages.some((x) => x.id === m.id)) return false;
    this.messages.push(m);
    this.messages.sort((a, b) => a.ts - b.ts);
    this.saveMessages();
    this.changed();
    return true;
  }

  saveMessages() {
    clearTimeout(this.saveT);
    this.saveT = setTimeout(() => save('messages', this.messages.slice(-3000)), 400);
  }

  deleteMessage(id) {
    const p = this.progress[id];
    if (p && !p.finished && !p.failed) this.cancelTransfer(id);
    this.messages = this.messages.filter((m) => m.id !== id);
    delete this.progress[id];
    this.saveMessages();
    this.changed();
  }

  notify() {
    // تنبيه متخفي (شكل لعبة) لما البرنامج مو قدامك
    if (document.hasFocus() && !document.hidden && !this.locked) return;
    try { new Notification('Jelly Jump', { body: '🎁 مكافأة جديدة بانتظارك!', silent: false }); } catch (_) {}
  }

  // ---------- التقدّم ----------

  setNote(bid, note) {
    const st = this.progress[bid] || (this.progress[bid] = newState());
    st.note = note;
    this.changed();
  }

  setBytes(bid, bytes, force = false) {
    const t = Date.now();
    const st = this.progress[bid] || (this.progress[bid] = newState());
    if (!force && st.lastPub && t - st.lastPub < 250) { st.bytes = bytes; return; }
    st.lastPub = t;
    const ls = this.lastSample[bid];
    if (ls) {
      const dt = (t - ls[0]) / 1000;
      if (dt >= 0.8) {
        const inst = Math.max(0, (bytes - ls[1]) / dt);
        st.speed = st.speed === 0 ? inst : st.speed * 0.5 + inst * 0.5;
        this.lastSample[bid] = [t, bytes];
      }
    } else this.lastSample[bid] = [t, bytes];
    if (!st.started && bytes > 0) { st.started = t; st.startBytes = st.bytes; }
    st.bytes = bytes;
    this.changed();
  }

  finish(bid, ok, note = '', quiet = false) {
    const st = this.progress[bid] || (this.progress[bid] = newState());
    const m = this.messages.find((x) => x.id === bid);
    if (ok && st.started) {
      const dt = (Date.now() - st.started) / 1000;
      const moved = ((m && m.batch && m.batch.size) || st.bytes) - st.startBytes;
      if (dt > 1 && moved > 0) st.avg = moved / dt;
    }
    st.finished = ok;
    st.failed = !ok;
    st.speed = 0;
    st.note = note;
    if (ok && m && m.batch) st.bytes = m.batch.size;
    if (m) m.status = ok ? 'done' : 'failed';
    delete this.lastSample[bid];
    this.saveMessages();
    this.changed();
  }

  markCancelled(bid) {
    const m = this.messages.find((x) => x.id === bid);
    if (m) m.status = 'cancelled';
    this.saveMessages();
  }

  // ---------- الاستقبال ----------

  recvEvents() {
    return {
      onStart: (m, from) => this.recvStart(m, from),
      onProgress: (m, from, b) => this.recvProgress(m, b),
      onFinish: (m, from, top) => this.recvFinish(m, from, top),
      onFail: (m) => this.recvFail(m),
    };
  }

  recvStart(meta, from) {
    const ex = this.messages.find((x) => x.id === meta.bid);
    if (ex) {
      const p = this.progress[meta.bid];
      if ((p && p.failed) || ex.status === 'failed' || ex.status === 'cancelled') {
        this.cancelled.delete(meta.bid);
        if (p) { p.failed = false; p.note = ''; }
        ex.status = 'active';
        this.changed();
      }
      return;
    }
    this.appendMessage({
      id: meta.bid, peer: from, ts: now(), outgoing: false, status: 'active',
      batch: { bid: meta.bid, name: meta.bname, size: meta.bsize, count: meta.bcount, isFolder: meta.folder, kind: meta.kind },
    });
    this.addFriendIfNeeded(from);
    this.progress[meta.bid] = newState();
    this.recvBase[meta.bid] = 0;
    this.recvCount[meta.bid] = 0;
  }

  recvProgress(meta, bytes) {
    const p = this.progress[meta.bid];
    if (p && (p.failed || p.finished)) return;
    (this.recvLive[meta.bid] = this.recvLive[meta.bid] || {})[meta.rel] = bytes;
    const live = Object.values(this.recvLive[meta.bid]).reduce((a, b) => a + b, 0);
    this.setBytes(meta.bid, (this.recvBase[meta.bid] || 0) + live);
  }

  recvFinish(meta, from, top) {
    if (this.cancelled.has(meta.bid)) return;
    if (this.recvLive[meta.bid]) delete this.recvLive[meta.bid][meta.rel];
    const done = (this.recvDone[meta.bid] = this.recvDone[meta.bid] || new Set());
    if (done.has(meta.rel)) return;
    done.add(meta.rel);
    this.recvBase[meta.bid] = (this.recvBase[meta.bid] || 0) + meta.size;
    this.recvCount[meta.bid] = (this.recvCount[meta.bid] || 0) + 1;
    const m = this.messages.find((x) => x.id === meta.bid);
    if (m) m.localPath = path.join(this.receivedDir, top);
    const st = this.progress[meta.bid] || (this.progress[meta.bid] = newState());
    st.files = this.recvCount[meta.bid];
    const live = Object.values(this.recvLive[meta.bid] || {}).reduce((a, b) => a + b, 0);
    this.setBytes(meta.bid, this.recvBase[meta.bid] + live, true);
    if (this.recvCount[meta.bid] >= meta.bcount) {
      delete this.recvLive[meta.bid];
      this.finish(meta.bid, true);
      if (this.activeChat === from) this.markRead(from);
      this.notify();
    }
  }

  recvFail(meta) {
    const p = this.progress[meta.bid];
    if ((p && p.finished) || this.cancelled.has(meta.bid)) return;
    this.finish(meta.bid, false, 'انقطع النقل. بيكمل تلقائياً لما يرجع الاتصال.', true);
  }

  // ---------- الإرسال ----------

  startSend(paths, peer) {
    for (const p of paths) {
      let listing;
      try { listing = listFiles(p); } catch (_) { this.toast('ما قدرت أقرأ: ' + path.basename(p)); continue; }
      if (!listing.files.length) { this.toast('ما لقيت ملفات داخل: ' + path.basename(p)); continue; }
      const bid = uuid();
      const total = listing.files.reduce((a, f) => a + f.size, 0);
      const batch = { bid, name: path.basename(p), size: total, count: listing.files.length,
        isFolder: listing.isFolder, kind: listing.isFolder ? 'folder' : kindOf(p) };
      this.appendMessage({ id: bid, peer, ts: now(), outgoing: true, status: 'active', batch, localPath: p });
      this.progress[bid] = newState();
      this.runBatch(bid, listing, batch, peer);
    }
    if (!this.online[peer]) this.toast(`@${peer} مو متصل. الملف بيوصله أول ما يدخل`);
  }

  async runBatch(bid, listing, batch, peer) {
    const task = { cancel: false };
    this.sendTasks[bid] = task;
    try {
      await this.transferBatch(listing, bid, batch, peer, task);
    } finally {
      if (this.sendTasks[bid] === task) delete this.sendTasks[bid];
    }
  }

  async transferBatch(listing, bid, batch, peer, task) {
    const tr = { base: 0, done: 0, live: {} };
    const total = () => tr.base + Object.values(tr.live).reduce((a, b) => a + b, 0);
    const BIG = 64 * 1024 * 1024;
    const MAXP = 4;
    let failed = false;
    let next = 0;
    const running = new Set();

    await new Promise((resolveAll) => {
      const launch = () => {
        while (next < listing.files.length && running.size < MAXP && !failed && !task.cancel) {
          const idx = next;
          const f = listing.files[idx];
          if (f.size >= BIG && running.size > 0) break;
          next++;
          const meta = { bid, bname: batch.name, bsize: batch.size, bcount: batch.count,
            folder: batch.isFolder, kind: batch.kind, rel: f.rel, size: f.size };
          const p = this.sendOne(f, meta, peer, bid, task, (cur) => { tr.live[idx] = cur; this.setBytes(bid, total()); })
            .then((ok) => {
              running.delete(p);
              delete tr.live[idx];
              if (ok) {
                tr.base += f.size;
                tr.done++;
                const st = this.progress[bid] || (this.progress[bid] = newState());
                st.files = tr.done;
                st.note = '';
                this.setBytes(bid, total(), true);
              } else failed = true;
              launch();
            });
          running.add(p);
          if (f.size >= BIG) break;
        }
        if (!running.size) resolveAll();
      };
      launch();
    });

    if (task.cancel || this.cancelled.has(bid)) return;
    if (failed || tr.done < listing.files.length) this.finish(bid, false, 'ما اكتمل الإرسال. اضغط «أعد الإرسال» وبيكمل من نفس المكان.');
    else this.finish(bid, true);
  }

  async sendOne(f, meta, peer, bid, task, onBytes) {
    for (let attempt = 1; attempt <= 8; attempt++) {
      if (task.cancel || this.cancelled.has(bid)) return false;
      await this.waitOnline(peer, bid, task);
      if (task.cancel) return false;
      const ok = await this.waitConnected(peer, attempt === 1 ? 20 : 90, task);
      const link = this.links[peer];
      if (!ok || !link) { if (attempt >= 4) return false; continue; }
      try {
        await link.sendFile(meta, f.path, f.size, onBytes);
        return true;
      } catch (_) {
        if (task.cancel) return false;
        this.setNote(bid, 'انقطع الاتصال، جاري إعادة المحاولة…');
        await sleep(1500);
      }
    }
    return false;
  }

  isSending(bid) { return !!this.sendTasks[bid]; }

  retrySend(m, silent = false) {
    if (!m.outgoing || !m.batch || this.sendTasks[m.id]) return;
    if (!m.localPath || !fs.existsSync(m.localPath)) {
      if (!silent) this.toast('ما لقيت الملف الأصلي، أرسله من جديد');
      return;
    }
    let listing;
    try { listing = listFiles(m.localPath); } catch (_) { return; }
    this.cancelled.delete(m.id);
    m.status = 'active';
    this.progress[m.id] = newState();
    delete this.lastSample[m.id];
    this.changed();
    this.runBatch(m.id, listing, m.batch, m.peer);
  }

  cancelTransfer(bid) {
    const m = this.messages.find((x) => x.id === bid);
    if (!m) return;
    this.cancelled.add(bid);
    if (this.sendTasks[bid]) this.sendTasks[bid].cancel = true;
    // نسكّر الاتصال الحالي للملفات الجارية حتى تتوقف فوراً
    const l = this.links[m.peer];
    if (l && m.outgoing) l.outs.forEach((o) => { if (o.bid === bid) o.abort(); });
    this.sendTo(m.peer, { t: 'cancel', bid });
    this.finish(bid, false, 'أُلغي النقل', true);
    this.markCancelled(bid);
  }

  autoResume(u) {
    const cutoff = now() - 2 * 86400;
    for (const m of this.messages) {
      if (m.peer === u && m.outgoing && m.batch && m.status === 'failed' && m.ts > cutoff
        && !this.cancelled.has(m.id) && !this.sendTasks[m.id]) this.retrySend(m, true);
    }
  }
}

function newState() {
  return { bytes: 0, files: 0, speed: 0, finished: false, failed: false, note: '', started: 0, startBytes: 0, avg: 0 };
}

module.exports = { App, listFiles, kindOf };
