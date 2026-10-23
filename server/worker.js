// سيرفر الربط: يمرر الرسائل النصية وإشارات الاتصال بين الأصدقاء فقط.
// الملفات لا تمر من هنا أبداً، تنتقل مباشرة من جوال لجوال (WebRTC).

export class Room {
  constructor(state, env) {
    this.state = state;
    this.state.setWebSocketAutoResponse(new WebSocketRequestResponsePair("ping", "pong"));
  }

  async fetch(req) {
    if (req.headers.get("Upgrade") !== "websocket") return new Response("ok");
    const pair = new WebSocketPair();
    const [client, server] = Object.values(pair);
    this.state.acceptWebSocket(server);
    return new Response(null, { status: 101, webSocket: client });
  }

  others(ws) {
    return this.state.getWebSockets().filter((s) => s !== ws);
  }

  broadcast(ws, obj) {
    const t = JSON.stringify(obj);
    for (const s of this.others(ws)) {
      try { s.send(t); } catch (e) {}
    }
  }

  async webSocketMessage(ws, msg) {
    let m;
    try { m = JSON.parse(msg); } catch (e) { return; }

    if (m.type === "hello") {
      // لو نفس الجهاز مفتوح باتصال قديم نقفله
      for (const s of this.others(ws)) {
        const a = s.deserializeAttachment();
        if (a && a.id === m.id) { try { s.close(1000, "replaced"); } catch (e) {} }
      }
      ws.serializeAttachment({ id: m.id, name: m.name });
      const peers = this.others(ws)
        .map((s) => s.deserializeAttachment())
        .filter((a) => a && a.id !== m.id);
      ws.send(JSON.stringify({ type: "peers", peers }));
      const history = (await this.state.storage.get("h")) || [];
      ws.send(JSON.stringify({ type: "history", msgs: history }));
      this.broadcast(ws, { type: "join", id: m.id, name: m.name });
      return;
    }

    const me = ws.deserializeAttachment();
    if (!me) return;
    m.from = me.id;

    if (m.type === "chat" && m.msg) {
      m.msg.from = me.id;
      const history = (await this.state.storage.get("h")) || [];
      history.push(m.msg);
      while (history.length > 300) history.shift();
      await this.state.storage.put("h", history);
    }

    if (m.to) {
      const t = JSON.stringify(m);
      for (const s of this.others(ws)) {
        const a = s.deserializeAttachment();
        if (a && a.id === m.to) { try { s.send(t); } catch (e) {} }
      }
    } else {
      this.broadcast(ws, m);
    }
  }

  leave(ws) {
    const me = ws.deserializeAttachment();
    if (me) this.broadcast(ws, { type: "leave", id: me.id });
  }
  async webSocketClose(ws) { this.leave(ws); }
  async webSocketError(ws) { this.leave(ws); }
}

export default {
  async fetch(req, env) {
    const room = new URL(req.url).searchParams.get("room");
    if (!room || room.length < 6) return new Response("room?", { status: 400 });
    const id = env.ROOM.idFromName(room);
    return env.ROOM.get(id).fetch(req);
  },
};
