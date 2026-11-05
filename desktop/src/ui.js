// واجهة البرنامج + التنقل بين اللعبة والبرنامج
const { ipcRenderer, webUtils } = require('electron');
const { App } = require('./app.js');
const { startGame } = require('./game.js');
const { LANES } = require('./peer.js');

const $ = (id) => document.getElementById(id);
const app = new App();
let current = null;
let unlocked = false;

// ---------------- أدوات ----------------

const esc = (s) => String(s).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
function fmtSize(b) {
  if (!b) return '0 B';
  const u = ['B', 'KB', 'MB', 'GB', 'TB'];
  const i = Math.min(u.length - 1, Math.floor(Math.log(b) / Math.log(1000)));
  return (b / Math.pow(1000, i)).toFixed(i ? 1 : 0) + ' ' + u[i];
}
const fmtSpeed = (b) => fmtSize(b) + '/ث';
function fmtEta(s) {
  if (!isFinite(s) || s <= 0) return '';
  s = Math.round(s);
  if (s < 60) return s + ' ث';
  if (s < 3600) return Math.floor(s / 60) + ' د';
  return Math.floor(s / 3600) + ' س ' + Math.floor((s % 3600) / 60) + ' د';
}
function fmtTime(ts) {
  const d = new Date(ts * 1000);
  const today = new Date().toDateString() === d.toDateString();
  return today ? d.toLocaleTimeString('ar', { hour: 'numeric', minute: '2-digit' })
    : d.toLocaleDateString('ar', { day: 'numeric', month: 'short' });
}
const PAIRS = [['#56A8FF', '#2563EB'], ['#A78BFA', '#6D3FE0'], ['#34D3C0', '#0E8FA8'], ['#FF8FB1', '#E0457A'], ['#FFB45C', '#F07A2A'], ['#4ADE80', '#16A06A']];
function avatar(el, name, online) {
  let h = 0;
  for (const ch of name) h = (h * 31 + ch.codePointAt(0)) & 0xffff;
  const p = PAIRS[h % PAIRS.length];
  el.style.background = `linear-gradient(${p[0]}, ${p[1]})`;
  el.innerHTML = esc(name.slice(0, 1).toUpperCase()) + (online === undefined ? '' : `<span class="dot ${online ? 'on' : ''}"></span>`);
}
function avatarHTML(name, online) {
  const d = document.createElement('div');
  d.className = 'avatar';
  avatar(d, name, online);
  return d.outerHTML;
}
let toastT;
function toast(s) {
  const t = $('toast');
  t.textContent = s;
  t.hidden = false;
  clearTimeout(toastT);
  toastT = setTimeout(() => { t.hidden = true; }, 2600);
}
app.addEventListener('toast', (e) => toast(e.text));

// ---------------- اللعبة والقفل ----------------

const game = startGame($('game'), unlock);

function unlock() {
  unlocked = true;
  app.locked = false;
  if (current) app.markRead(current);
  game.pause();
  $('game').hidden = true;
  $('app').hidden = false;
  render();
  if (app.isSetup) app.start();
}

function lock() {
  if (!unlocked) return;
  unlocked = false;
  app.locked = true;
  closeModal();
  $('app').hidden = true;
  $('game').hidden = false;
  game.resume();
}

ipcRenderer.on('lock', lock);
document.addEventListener('keydown', (e) => {
  if (e.key === 'Escape' && unlocked && $('modal').hidden) lock();
});
$('b-lock').onclick = lock;

// البرنامج يشتغل بالخلفية من البداية (حتى يستقبل وأنت باللعبة)
if (app.isSetup) app.start();

// ---------------- الترحيب ----------------

$('w-name').addEventListener('input', (e) => {
  const v = e.target.value.toLowerCase().replace(/[^a-z0-9_]/g, '').slice(0, 20);
  if (v !== e.target.value) e.target.value = v;
});
$('w-go').onclick = () => {
  if (!app.register($('w-name').value)) {
    $('w-hint').textContent = 'اكتب من 3 إلى 20 حرف إنجليزي أو أرقام';
    $('w-hint').style.color = 'var(--warn)';
    return;
  }
  render();
};
$('w-name').addEventListener('keydown', (e) => { if (e.key === 'Enter') $('w-go').click(); });

// ---------------- القائمة ----------------

$('search').addEventListener('input', renderFriends);

function renderFriends() {
  const q = $('search').value.toLowerCase();
  let list = [...app.friends].sort((a, b) => ((app.last(b.id) || {}).ts || b.addedAt) - ((app.last(a.id) || {}).ts || a.addedAt));
  if (q) list = list.filter((f) => f.id.includes(q));
  if (!list.length) {
    $('friends').innerHTML = `<p class="muted small" style="padding:16px;text-align:center">${app.friends.length ? 'ما فيه نتائج' : 'ما عندك أصدقاء. اضغط ＋ وأضف اسم صديقك.'}</p>`;
    return;
  }
  $('friends').innerHTML = list.map((f) => {
    const l = app.last(f.id);
    const un = app.unread(f.id);
    const prev = l ? (l.batch ? (l.outgoing ? 'أرسلت: ' : '📎 ') + l.batch.name : l.text) : 'ابدأ المحادثة';
    return `<div class="row ${current === f.id ? 'active' : ''}" data-id="${esc(f.id)}">
      ${avatarHTML(f.id, !!app.online[f.id])}
      <div class="info">
        <div class="top"><span class="bold">@${esc(f.id)}</span><span class="small muted">${l ? fmtTime(l.ts) : ''}</span></div>
        <div class="top"><span class="prev">${esc(prev)}</span>${un ? `<span class="badge">${un}</span>` : ''}</div>
      </div></div>`;
  }).join('');
  $('friends').querySelectorAll('.row').forEach((r) => {
    r.onclick = () => openChat(r.dataset.id);
    r.oncontextmenu = (e) => {
      e.preventDefault();
      confirmBox(`حذف @${r.dataset.id} من القائمة؟`, 'حذف', () => {
        app.removeFriend(r.dataset.id);
        if (current === r.dataset.id) { current = null; app.activeChat = null; }
        render();
      });
    };
  });
}

function openChat(id) {
  current = id;
  app.activeChat = id;
  app.markRead(id);
  lastRenderedCount = -1;
  render();
  $('text').focus();
}

// ---------------- المحادثة ----------------

let lastRenderedCount = -1;

function statusText(peer) {
  if (app.isDirect(peer)) {
    const n = app.lanes[peer] || 0;
    return n > 1 ? `اتصال مباشر ⚡ ${n}/${LANES}` : 'متصل • اتصال مباشر ⚡';
  }
  return app.online[peer] ? 'متصل' : 'غير متصل';
}

function renderChat() {
  if (!current) { $('empty').hidden = false; $('chat-wrap').hidden = true; return; }
  $('empty').hidden = true;
  $('chat-wrap').hidden = false;
  avatar($('peer-avatar'), current);
  $('peer-name').textContent = '@' + current;
  const st = $('peer-status');
  st.textContent = statusText(current);
  st.style.color = app.online[current] ? 'var(--ok)' : 'var(--text2)';

  const b = $('banner');
  if (!app.online[current]) {
    b.hidden = false; b.className = 'banner off';
    b.textContent = 'صديقك مو متصل. الرسائل توصله لما يدخل، والملفات تنرسل أول ما يدخل (خل البرنامج مفتوح).';
  } else if (!app.isDirect(current)) {
    b.hidden = false; b.className = 'banner wait';
    b.textContent = 'جاري تجهيز الاتصال المباشر…';
  } else b.hidden = true;

  const box = $('msgs');
  const atBottom = box.scrollHeight - box.scrollTop - box.clientHeight < 80;
  const msgs = app.chat(current).slice(-400);
  box.innerHTML = msgs.map(msgHTML).join('');
  if (atBottom || msgs.length !== lastRenderedCount) box.scrollTop = box.scrollHeight;
  if (msgs.length !== lastRenderedCount) app.markRead(current);
  lastRenderedCount = msgs.length;
}

function msgHTML(m) {
  const side = m.outgoing ? 'mine' : 'theirs';
  if (!m.batch) {
    const tick = m.outgoing ? (m.delivered ? ' ✓✓' : ' ✓') : '';
    return `<div class="m ${side}" data-id="${esc(m.id)}"><div class="bubble">${esc(m.text || '')}<div class="meta">${fmtTime(m.ts)}${tick}</div></div></div>`;
  }
  const b = m.batch;
  const live = app.progress[m.id];
  const done = live ? live.finished : m.status === 'done';
  const failed = live ? live.failed : (m.status === 'failed' || m.status === 'cancelled');
  const frac = live ? Math.min(1, live.bytes / Math.max(1, b.size)) : (done ? 1 : 0);
  const icon = { video: '🎬', image: '🖼', folder: '📁' }[b.kind] || '📄';
  let sub = fmtSize(b.size) + (b.isFolder ? ` • ${b.count} ملف` : '');
  if (done) {
    sub += m.outgoing ? ' • أُرسل ✓' : ' • وصل ✓';
    if (live && live.avg) sub += ' • ' + fmtSpeed(live.avg);
  }
  let body = '';
  if (!done && !failed) {
    let p = `<b>${Math.floor(frac * 100)}%</b>`;
    if (live && live.speed > 0) {
      p += ` • ${fmtSpeed(live.speed)}`;
      const e = fmtEta((b.size - live.bytes) / live.speed);
      if (e) p += ` • باقي ${e}`;
    }
    if (b.isFolder && live && live.files) p += ` • ${live.files}/${b.count}`;
    body = `<div class="bar"><i style="width:${Math.max(2, frac * 100)}%"></i></div>
      <div class="prog">${p}<button class="x" data-act="cancel" title="إلغاء">✕</button></div>
      ${live && live.note ? `<div class="note">${esc(live.note)}</div>` : ''}`;
  } else if (failed) {
    const note = (live && live.note) || (m.status === 'cancelled' ? 'أُلغي النقل' : 'ما اكتمل النقل');
    body = `<div class="acts"><span class="err">${esc(note)}</span>
      ${m.outgoing ? '<button class="pill" data-act="retry">↻ أعد الإرسال</button>' : ''}</div>`;
  }
  const canOpen = m.localPath && (done || m.outgoing);
  const acts = canOpen ? `<div class="acts">
      ${!b.isFolder ? '<button class="pill" data-act="open">فتح</button>' : ''}
      <button class="pill" data-act="show">إظهار في المجلد</button></div>` : '';
  return `<div class="m ${side}" data-id="${esc(m.id)}"><div class="card">
    <div class="h"><div class="ic">${icon}</div><div><div class="nm">${esc(b.name)}</div><div class="small muted">${sub}</div></div></div>
    ${body}${acts}<div class="meta">${fmtTime(m.ts)}</div></div></div>`;
}


// أزرار الرسائل بالتفويض (العناصر تنعاد رسمها أثناء النقل، فنتصرف على mousedown)
$('msgs').addEventListener('mousedown', (e) => {
  if (e.button !== 0) return;
  const btn = e.target.closest('[data-act]');
  if (!btn) return;
  const el = btn.closest('.m');
  const m = el && app.messages.find((x) => x.id === el.dataset.id);
  if (!m) return;
  e.preventDefault();
  const a = btn.dataset.act;
  if (a === 'cancel') confirmBox('إلغاء النقل؟', 'إلغاء النقل', () => app.cancelTransfer(m.id));
  if (a === 'retry') app.retrySend(m);
  if (a === 'open') ipcRenderer.send('open-path', m.localPath);
  if (a === 'show') ipcRenderer.send('show-item', m.localPath);
});
$('msgs').addEventListener('contextmenu', (e) => {
  const el = e.target.closest('.m');
  const m = el && app.messages.find((x) => x.id === el.dataset.id);
  if (!m) return;
  e.preventDefault();
  if (m.text) {
    openModal(`<h3>رسالة</h3><div class="btns"><button class="btn" id="r-copy">نسخ</button><button class="btn danger" id="r-del">حذف</button><button class="btn" id="r-no">رجوع</button></div>`);
    $('r-copy').onclick = () => { require('electron').clipboard.writeText(m.text); closeModal(); toast('انسخ'); };
    $('r-del').onclick = () => { closeModal(); app.deleteMessage(m.id); };
    $('r-no').onclick = closeModal;
  } else {
    confirmBox('حذف من المحادثة؟ (الملف نفسه يبقى بمكانه)', 'حذف', () => app.deleteMessage(m.id));
  }
});

// ---------------- الكتابة والإرسال ----------------

const text = $('text');
function sendNow() {
  if (!current || !text.value.trim()) return;
  app.sendText(text.value, current);
  text.value = '';
  text.style.height = '';
}
text.addEventListener('keydown', (e) => {
  if (e.key === 'Enter' && !e.shiftKey) { e.preventDefault(); sendNow(); }
});
text.addEventListener('input', () => { text.style.height = ''; text.style.height = Math.min(140, text.scrollHeight) + 'px'; });
$('b-send').onclick = sendNow;
$('b-file').onclick = async () => { const p = await ipcRenderer.invoke('pick', false); if (p.length && current) app.startSend(p, current); };
$('b-folder').onclick = async () => { const p = await ipcRenderer.invoke('pick', true); if (p.length && current) app.startSend(p, current); };

// سحب وإفلات
let dragDepth = 0;
window.addEventListener('dragenter', (e) => { e.preventDefault(); if (unlocked && current) { dragDepth++; $('drop').hidden = false; } });
window.addEventListener('dragleave', () => { dragDepth = Math.max(0, dragDepth - 1); if (!dragDepth) $('drop').hidden = true; });
window.addEventListener('dragover', (e) => e.preventDefault());
window.addEventListener('drop', (e) => {
  e.preventDefault();
  dragDepth = 0;
  $('drop').hidden = true;
  if (!unlocked || !current) return;
  const paths = [...e.dataTransfer.files].map((f) => (webUtils && webUtils.getPathForFile ? webUtils.getPathForFile(f) : f.path)).filter(Boolean);
  if (paths.length) app.startSend(paths, current);
});

// ---------------- النوافذ ----------------

function openModal(html) { $('sheet').innerHTML = html; $('modal').hidden = false; }
function closeModal() { $('modal').hidden = true; $('sheet').innerHTML = ''; }
$('modal').addEventListener('mousedown', (e) => { if (e.target === $('modal')) closeModal(); });

function confirmBox(msg, okLabel, onOk) {
  openModal(`<h3>${esc(msg)}</h3><div class="btns"><button class="btn danger" id="c-ok">${esc(okLabel)}</button><button class="btn" id="c-no">رجوع</button></div>`);
  $('c-ok').onclick = () => { closeModal(); onOk(); };
  $('c-no').onclick = closeModal;
}

$('b-add').onclick = () => {
  openModal(`<h3>إضافة صديق</h3><label>اسم المستخدم حق صديقك</label>
    <input id="a-name" class="ltr" placeholder="username" autocomplete="off" spellcheck="false">
    <div class="btns"><button class="btn primary" id="a-ok">إضافة</button><button class="btn" id="a-no">رجوع</button></div>`);
  const inp = $('a-name');
  inp.focus();
  const go = () => {
    const n = inp.value.toLowerCase().replace(/[@\s]/g, '');
    if (!app.addFriend(n)) { toast('اسم غير صحيح'); return; }
    closeModal();
    openChat(n);
  };
  $('a-ok').onclick = go;
  inp.onkeydown = (e) => { if (e.key === 'Enter') go(); };
  $('a-no').onclick = closeModal;
};

$('b-settings').onclick = () => {
  const g = (k) => esc(localStorage.getItem(k) || '');
  openModal(`<h3>الإعدادات</h3>
    <p class="small muted">اسمك: <b class="ltr">@${esc(app.username)}</b> — هذا اللي يضيفك فيه أصدقاؤك</p>
    <p class="small muted">الملفات المستلمة تنحفظ في:<br><span class="ltr">${esc(app.receivedDir)}</span></p>
    <button class="btn" id="s-open">فتح مجلد الملفات المستلمة</button>
    <label>سيرفر TURN (اختياري، للنت اللي يمنع الاتصال المباشر)</label>
    <input id="s-turn" class="ltr" placeholder="turn:host:3478" value="${g('turnURL')}">
    <label>اسم المستخدم</label><input id="s-tu" class="ltr" value="${g('turnUser')}">
    <label>كلمة المرور</label><input id="s-tp" class="ltr" type="password" value="${g('turnPass')}">
    <p class="small muted">للإخفاء: Esc أو 🎮 يرجعك للعبة، وتصغير النافذة كذلك.</p>
    <div class="btns"><button class="btn primary" id="s-save">حفظ</button><button class="btn" id="s-no">رجوع</button></div>`);
  $('s-open').onclick = () => ipcRenderer.send('open-path', app.receivedDir);
  $('s-save').onclick = () => {
    localStorage.setItem('turnURL', $('s-turn').value.trim());
    localStorage.setItem('turnUser', $('s-tu').value.trim());
    localStorage.setItem('turnPass', $('s-tp').value);
    closeModal();
    toast('انحفظ. يطبق على الاتصالات الجديدة');
  };
  $('s-no').onclick = closeModal;
};

// ---------------- الرسم ----------------

function render() {
  if (!unlocked) return;
  if (!app.isSetup) { $('welcome').hidden = false; $('main').hidden = true; $('w-name').focus(); return; }
  $('welcome').hidden = true;
  $('main').hidden = false;
  avatar($('me-avatar'), app.username);
  $('me-name').textContent = '@' + app.username;
  $('net').textContent = app.mqttUp ? '● متصل' : '● جاري الاتصال…';
  $('net').style.color = app.mqttUp ? 'var(--ok)' : 'var(--warn)';
  document.title = 'Jelly Jump';
  renderFriends();
  renderChat();
}

app.addEventListener('change', render);
