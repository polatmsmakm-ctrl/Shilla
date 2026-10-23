// TextVast relay: وسيط تخزين مؤقت على Cloudflare Workers + R2.
// الملفات تنرفع مشفّرة بالنقل (HTTPS) وتنحذف بعد ما الصديق ينزّلها.
// الإعداد: ربط R2 باسم BUCKET + متغير سري KEY (نفس قيمة Secrets.key).

const json = (o, s = 200) =>
  new Response(JSON.stringify(o), { status: s, headers: { "content-type": "application/json" } });

export default {
  async fetch(req, env) {
    if (req.headers.get("x-key") !== env.KEY) return new Response("forbidden", { status: 401 });
    const url = new URL(req.url);
    const q = url.searchParams;
    const k = q.get("k") || "";
    if (!/^[A-Za-z0-9_\-\/]{1,200}$/.test(k)) return new Response("bad key", { status: 400 });
    const p = url.pathname;

    try {
      if (p === "/create" && req.method === "POST") {
        const u = await env.BUCKET.createMultipartUpload(k);
        return json({ id: u.uploadId });
      }
      if (p === "/part" && req.method === "PUT") {
        const u = env.BUCKET.resumeMultipartUpload(k, q.get("id"));
        const part = await u.uploadPart(Number(q.get("n")), req.body);
        return json({ etag: part.etag, n: part.partNumber });
      }
      if (p === "/done" && req.method === "POST") {
        const u = env.BUCKET.resumeMultipartUpload(k, q.get("id"));
        const parts = await req.json();
        const obj = await u.complete(parts);
        return json({ size: obj.size });
      }
      if (p === "/put" && req.method === "PUT") {
        const data = await req.arrayBuffer();
        await env.BUCKET.put(k, data);
        return json({ ok: 1 });
      }
      if (p === "/get" && req.method === "GET") {
        const s = Number(q.get("s") || 0);
        const l = q.get("l") ? Number(q.get("l")) : undefined;
        const head = await env.BUCKET.head(k);
        if (!head) return new Response("missing", { status: 404 });
        const len = Math.max(0, Math.min(l === undefined ? head.size - s : l, head.size - s));
        if (len === 0) return new Response(new Uint8Array(0), { headers: { "content-length": "0" } });
        const obj = await env.BUCKET.get(k, { range: { offset: s, length: len } });
        if (!obj) return new Response("missing", { status: 404 });
        return new Response(obj.body, {
          headers: { "content-length": String(len), "x-size": String(head.size) },
        });
      }
      if (p === "/del" && req.method === "DELETE") {
        await env.BUCKET.delete(k);
        return json({ ok: 1 });
      }
      return new Response("not found", { status: 404 });
    } catch (e) {
      return json({ error: String(e && e.message || e) }, 500);
    }
  },
};
