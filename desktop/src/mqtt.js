// عميل MQTT 3.1.1 فوق WebSocket — نفس سيرفرات ومنطق نسخة الآيفون.
// يتصل بالثلاثة بنفس الوقت، وكل رسالة تنرسل على الكل.

const BROKERS = process.env.JJ_BROKERS ? process.env.JJ_BROKERS.split(',') : [
  'wss://broker.emqx.io:8084/mqtt',
  'wss://broker.hivemq.com:8884/mqtt',
  'wss://test.mosquitto.org:8081/mqtt',
];

function utf(s) {
  const b = Buffer.from(s, 'utf8');
  return Buffer.concat([Buffer.from([b.length >> 8, b.length & 0xff]), b]);
}

function remLen(n) {
  const out = [];
  do {
    let d = n % 128;
    n = Math.floor(n / 128);
    if (n > 0) d |= 0x80;
    out.push(d);
  } while (n > 0);
  return Buffer.from(out);
}

class MQTTConn {
  constructor(url, index, hooks) {
    this.url = url;
    this.index = index;
    this.hooks = hooks;
    this.ws = null;
    this.wanted = false;
    this.connected = false;
    this.subs = new Set();
    this.queued = [];
    this.buffer = Buffer.alloc(0);
    this.packetId = 0;
    this.backoff = 2000;
    this.lastRx = Date.now();
  }

  connect(clientId, willTopic, willPayload) {
    this.clientId = clientId;
    this.willTopic = willTopic;
    this.willPayload = Buffer.from(willPayload);
    this.wanted = true;
    if (!this.ws) this.open();
  }

  subscribe(topic) {
    if (this.subs.has(topic)) return;
    this.subs.add(topic);
    if (this.connected) this.sendSubscribe(topic);
  }

  publish(topic, payload, retain, queue) {
    if (this.connected) this.sendPublish(topic, payload, retain);
    else if (queue) {
      if (this.queued.length > 300) this.queued.shift();
      this.queued.push([topic, payload, retain]);
    }
  }

  open() {
    if (!this.wanted) return;
    this.buffer = Buffer.alloc(0);
    this.connected = false;
    this.lastRx = Date.now();
    let ws;
    try {
      ws = new WebSocket(this.url, ['mqtt']);
    } catch (_) {
      this.retryLater();
      return;
    }
    ws.binaryType = 'arraybuffer';
    this.ws = ws;
    ws.onopen = () => { if (this.ws === ws) this.sendConnect(); };
    ws.onmessage = (e) => {
      if (this.ws !== ws) return;
      this.lastRx = Date.now();
      const chunk = typeof e.data === 'string' ? Buffer.from(e.data, 'utf8') : Buffer.from(e.data);
      this.buffer = Buffer.concat([this.buffer, chunk]);
      this.parse();
    };
    ws.onclose = () => this.fail(ws);
    ws.onerror = () => this.fail(ws);
    setTimeout(() => { if (this.ws === ws && !this.connected) this.fail(ws); }, 12000);
    const ping = setInterval(() => {
      if (this.ws !== ws) { clearInterval(ping); return; }
      if (this.connected && Date.now() - this.lastRx > 40000) { this.fail(ws); return; }
      if (this.connected) this.send(Buffer.from([0xc0, 0x00]));
    }, 15000);
  }

  fail(ws) {
    if (this.ws !== ws) return;
    const was = this.connected;
    this.ws = null;
    this.connected = false;
    try { ws.close(); } catch (_) {}
    if (was) this.hooks.onState(this.index, false);
    this.retryLater();
  }

  retryLater() {
    const wait = this.backoff;
    this.backoff = Math.min(this.backoff * 2, 30000);
    setTimeout(() => { if (this.wanted && !this.ws) this.open(); }, wait);
  }

  parse() {
    while (this.buffer.length >= 2) {
      let mult = 1, len = 0, idx = 1, complete = false;
      while (idx < this.buffer.length && idx <= 4) {
        const b = this.buffer[idx];
        len += (b & 0x7f) * mult;
        mult *= 128;
        idx++;
        if ((b & 0x80) === 0) { complete = true; break; }
      }
      if (!complete || this.buffer.length < idx + len) return;
      const first = this.buffer[0];
      const body = this.buffer.subarray(idx, idx + len);
      this.buffer = this.buffer.subarray(idx + len);
      this.handle(first, Buffer.from(body));
    }
  }

  handle(first, body) {
    switch (first >> 4) {
      case 2: // CONNACK
        if (body.length >= 2 && body[1] === 0) {
          this.connected = true;
          this.backoff = 2000;
          this.hooks.onState(this.index, true);
          for (const s of this.subs) this.sendSubscribe(s);
          const pending = this.queued;
          this.queued = [];
          for (const [t, p, r] of pending) this.sendPublish(t, p, r);
          this.hooks.onConnected(this.index);
        } else if (this.ws) this.fail(this.ws);
        break;
      case 3: { // PUBLISH
        const qos = (first >> 1) & 3;
        if (body.length < 2) return;
        const tl = (body[0] << 8) | body[1];
        if (body.length < 2 + tl) return;
        const topic = body.subarray(2, 2 + tl).toString('utf8');
        let i = 2 + tl;
        let pid = null;
        if (qos > 0) {
          if (body.length < i + 2) return;
          pid = [body[i], body[i + 1]];
          i += 2;
        }
        const payload = Buffer.from(body.subarray(i));
        if (qos === 1) this.send(Buffer.from([0x40, 0x02, pid[0], pid[1]]));
        this.hooks.onMessage(topic, payload, this.index);
        break;
      }
      default: break;
    }
  }

  nextId() {
    this.packetId = (this.packetId + 1) & 0xffff;
    if (this.packetId === 0) this.packetId = 1;
    return this.packetId;
  }

  send(buf) {
    if (this.ws && this.ws.readyState === WebSocket.OPEN) this.ws.send(buf);
  }

  sendConnect() {
    const flags = 0x04 | 0x08 | 0x20; // will + will QoS1 + will retain، جلسة محفوظة
    const vh = Buffer.concat([utf('MQTT'), Buffer.from([4, flags, 0, 30])]);
    const pl = Buffer.concat([
      utf(this.clientId), utf(this.willTopic),
      Buffer.from([this.willPayload.length >> 8, this.willPayload.length & 0xff]), this.willPayload,
    ]);
    const body = Buffer.concat([vh, pl]);
    this.send(Buffer.concat([Buffer.from([0x10]), remLen(body.length), body]));
  }

  sendSubscribe(topic) {
    const id = this.nextId();
    const body = Buffer.concat([Buffer.from([id >> 8, id & 0xff]), utf(topic), Buffer.from([1])]);
    this.send(Buffer.concat([Buffer.from([0x82]), remLen(body.length), body]));
  }

  sendPublish(topic, payload, retain) {
    const id = this.nextId();
    const body = Buffer.concat([utf(topic), Buffer.from([id >> 8, id & 0xff]), Buffer.from(payload)]);
    const header = 0x30 | (1 << 1) | (retain ? 1 : 0);
    this.send(Buffer.concat([Buffer.from([header]), remLen(body.length), body]));
  }
}

class MQTTClient {
  constructor(hooks) {
    this.conns = BROKERS.map((u, i) => new MQTTConn(u, i, hooks));
  }
  connect(clientId, willTopic, willPayload) {
    this.conns.forEach((c) => c.connect(clientId, willTopic, willPayload));
  }
  subscribe(topic) { this.conns.forEach((c) => c.subscribe(topic)); }
  publish(topic, payload, { retain = false, queue = true, only = null } = {}) {
    for (const c of this.conns) if (only === null || only === c.index) c.publish(topic, payload, retain, queue);
  }
}

module.exports = { MQTTClient, BROKERS };
