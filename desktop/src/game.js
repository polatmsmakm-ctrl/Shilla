// لعبة Jelly Jump: لعبة جري بسيطة تشتغل فعلاً (مسافة/قفز/عملات).
// السر: ضغطة مطوّلة على الغيمة الكبيرة 3.5 ثانية = يفتح البرنامج.

const HOLD_MS = 3500;

function startGame(canvas, onReveal) {
  const ctx = canvas.getContext('2d');
  let W = 0, H = 0, dpr = 1;
  let running = true;
  let best = Number(localStorage.getItem('jj_best') || 0);

  const g = {
    state: 'ready', // ready | play | over
    t: 0, speed: 330, score: 0, coins: 0,
    y: 0, vy: 0, squash: 0,
    obs: [], coinsList: [], spawnIn: 1.2, coinIn: 0.8, groundOff: 0,
  };
  const cloud = { x: 0, y: 0, r: 0 };
  let hold = null; // {start, id}

  function resize() {
    dpr = window.devicePixelRatio || 1;
    W = canvas.clientWidth; H = canvas.clientHeight;
    canvas.width = Math.round(W * dpr); canvas.height = Math.round(H * dpr);
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
  }
  window.addEventListener('resize', resize);
  resize();

  const groundY = () => H - Math.max(70, H * 0.14);
  const jellyR = () => Math.max(26, Math.min(W, H) * 0.055);
  const jellyX = () => Math.max(90, W * 0.18);

  function reset() {
    g.state = 'play'; g.t = 0; g.speed = 330; g.score = 0; g.coins = 0;
    g.y = 0; g.vy = 0; g.obs = []; g.coinsList = []; g.spawnIn = 1.0; g.coinIn = 0.6;
  }

  function jump() {
    if (g.state !== 'play') { reset(); return; }
    if (g.y <= 0.5) { g.vy = 820; g.squash = -0.25; }
  }

  function inCloud(px, py) {
    const dx = (px - cloud.x) / (cloud.r * 1.6), dy = (py - cloud.y) / (cloud.r * 0.9);
    return dx * dx + dy * dy <= 1;
  }

  function pos(e) {
    const r = canvas.getBoundingClientRect();
    return [e.clientX - r.left, e.clientY - r.top];
  }

  canvas.addEventListener('pointerdown', (e) => {
    const [x, y] = pos(e);
    if (inCloud(x, y)) {
      hold = { start: performance.now(), id: e.pointerId };
      canvas.setPointerCapture(e.pointerId);
      return;
    }
    jump();
  });
  canvas.addEventListener('pointermove', (e) => {
    if (!hold || e.pointerId !== hold.id) return;
    const [x, y] = pos(e);
    if (!inCloud(x, y)) hold = null;
  });
  const endHold = (e) => { if (hold && e.pointerId === hold.id) hold = null; };
  canvas.addEventListener('pointerup', endHold);
  canvas.addEventListener('pointercancel', endHold);
  window.addEventListener('keydown', (e) => {
    if (!running) return;
    if (e.code === 'Space' || e.code === 'ArrowUp') { e.preventDefault(); jump(); }
  });

  function update(dt) {
    cloud.r = Math.max(48, Math.min(W, H) * 0.09);
    cloud.x = W * 0.72;
    cloud.y = H * 0.2 + Math.sin(performance.now() / 1400) * 6;

    if (hold && performance.now() - hold.start >= HOLD_MS) {
      hold = null;
      onReveal();
      return;
    }
    g.squash *= Math.pow(0.001, dt);
    if (g.state !== 'play') return;
    g.t += dt;
    g.speed = 330 + Math.min(420, g.t * 9);
    g.score += dt * g.speed / 40;
    g.groundOff = (g.groundOff + g.speed * dt) % 64;

    g.vy -= 2300 * dt;
    g.y = Math.max(0, g.y + g.vy * dt);
    if (g.y === 0 && g.vy < 0) { if (g.vy < -300) g.squash = 0.3; g.vy = 0; }

    g.spawnIn -= dt;
    if (g.spawnIn <= 0) {
      const tall = Math.random() < 0.35;
      g.obs.push({ x: W + 40, w: tall ? 34 : 46, h: tall ? 70 : 42 });
      g.spawnIn = 0.9 + Math.random() * 1.1 - Math.min(0.4, g.t * 0.006);
    }
    g.coinIn -= dt;
    if (g.coinIn <= 0) {
      g.coinsList.push({ x: W + 30, y: 60 + Math.random() * 110, got: false });
      g.coinIn = 0.7 + Math.random() * 1.2;
    }
    for (const o of g.obs) o.x -= g.speed * dt;
    for (const c of g.coinsList) c.x -= g.speed * dt;
    g.obs = g.obs.filter((o) => o.x > -80);
    g.coinsList = g.coinsList.filter((c) => c.x > -40 && !c.got);

    const jr = jellyR(), jx = jellyX(), jy = groundY() - jr - g.y;
    for (const o of g.obs) {
      const top = groundY() - o.h;
      const cx = Math.max(o.x, Math.min(jx, o.x + o.w));
      const cy = Math.max(top, Math.min(jy, groundY()));
      if ((jx - cx) ** 2 + (jy - cy) ** 2 < (jr * 0.82) ** 2) {
        g.state = 'over';
        const s = Math.floor(g.score);
        if (s > best) { best = s; localStorage.setItem('jj_best', String(best)); }
      }
    }
    for (const c of g.coinsList) {
      const cy = groundY() - c.y;
      if ((jx - c.x) ** 2 + (jy - cy) ** 2 < (jr + 16) ** 2) { c.got = true; g.coins++; g.score += 25; }
    }
  }

  function drawCloud(x, y, r, a) {
    ctx.save();
    ctx.globalAlpha = a;
    ctx.fillStyle = '#ffffff';
    ctx.beginPath();
    ctx.arc(x - r * 0.9, y + r * 0.15, r * 0.6, 0, Math.PI * 2);
    ctx.arc(x - r * 0.25, y - r * 0.25, r * 0.78, 0, Math.PI * 2);
    ctx.arc(x + r * 0.55, y - r * 0.05, r * 0.68, 0, Math.PI * 2);
    ctx.arc(x + r * 1.05, y + r * 0.25, r * 0.48, 0, Math.PI * 2);
    ctx.rect(x - r * 0.9, y + r * 0.1, r * 1.95, r * 0.6);
    ctx.fill('nonzero');
    ctx.restore();
  }

  function draw() {
    const sky = ctx.createLinearGradient(0, 0, 0, H);
    sky.addColorStop(0, '#ff9640'); sky.addColorStop(0.55, '#c8608a'); sky.addColorStop(1, '#7a3cc8');
    ctx.fillStyle = sky; ctx.fillRect(0, 0, W, H);
    const sun = ctx.createRadialGradient(W * 0.78, H * 0.28, 10, W * 0.78, H * 0.28, H * 0.45);
    sun.addColorStop(0, 'rgba(255,235,150,0.85)'); sun.addColorStop(1, 'rgba(255,235,150,0)');
    ctx.fillStyle = sun; ctx.fillRect(0, 0, W, H);

    drawCloud(cloud.x, cloud.y, cloud.r, 1);

    const gy = groundY();
    ctx.fillStyle = '#2eaa6e';
    ctx.beginPath(); ctx.ellipse(W * 0.18, gy + 30, W * 0.42, H * 0.22, 0, Math.PI, 0); ctx.fill();
    ctx.fillStyle = '#228c5f';
    ctx.beginPath(); ctx.ellipse(W * 0.82, gy + 30, W * 0.42, H * 0.18, 0, Math.PI, 0); ctx.fill();

    for (let x = -g.groundOff; x < W + 64; x += 64) {
      ctx.fillStyle = '#8c5028'; roundRect(x + 2, gy + 10, 60, H - gy, 8);
      ctx.fillStyle = '#5fcd5a'; roundRect(x + 2, gy, 60, 22, 8);
    }

    for (const c of g.coinsList) {
      const cy = gy - c.y;
      ctx.fillStyle = '#c88200'; ctx.beginPath(); ctx.arc(c.x, cy, 15, 0, Math.PI * 2); ctx.fill();
      ctx.fillStyle = '#ffcd28'; ctx.beginPath(); ctx.arc(c.x, cy - 1, 12, 0, Math.PI * 2); ctx.fill();
      ctx.fillStyle = '#fff09a'; roundRect(c.x - 3, cy - 8, 6, 14, 3);
    }

    for (const o of g.obs) {
      ctx.fillStyle = '#1f6f3e'; roundRect(o.x, gy - o.h, o.w, o.h + 4, 10);
      ctx.fillStyle = '#2f9a55';
      for (let k = 0; k < 3; k++) {
        const sx = o.x + (o.w / 3) * k;
        ctx.beginPath(); ctx.moveTo(sx, gy - o.h + 4); ctx.lineTo(sx + o.w / 6, gy - o.h - 12); ctx.lineTo(sx + o.w / 3, gy - o.h + 4); ctx.fill();
      }
    }

    const jr = jellyR(), jx = jellyX(), jy = gy - jr - g.y;
    const sx = 1 + g.squash, sy = 1 - g.squash;
    ctx.save(); ctx.translate(jx, jy + jr * (1 - sy)); ctx.scale(sx, sy);
    ctx.fillStyle = 'rgba(20,60,30,0.35)';
    ctx.beginPath(); ctx.ellipse(0, jr + g.y / sy + 2, jr * 0.8, 6, 0, 0, Math.PI * 2); ctx.fill();
    ctx.fillStyle = '#781ea0'; ctx.beginPath(); ctx.arc(0, 0, jr, 0, Math.PI * 2); ctx.fill();
    ctx.fillStyle = '#be46f0'; ctx.beginPath(); ctx.arc(0, 0, jr * 0.93, 0, Math.PI * 2); ctx.fill();
    ctx.fillStyle = 'rgba(240,180,255,0.9)'; ctx.beginPath(); ctx.ellipse(-jr * 0.3, -jr * 0.55, jr * 0.32, jr * 0.2, 0, 0, Math.PI * 2); ctx.fill();
    for (const ex of [-0.33, 0.33]) {
      ctx.fillStyle = '#fff'; ctx.beginPath(); ctx.ellipse(jr * ex, -jr * 0.05, jr * 0.24, jr * 0.28, 0, 0, Math.PI * 2); ctx.fill();
      ctx.fillStyle = '#1e1432'; ctx.beginPath(); ctx.ellipse(jr * ex + jr * 0.04, jr * 0.02, jr * 0.12, jr * 0.15, 0, 0, Math.PI * 2); ctx.fill();
    }
    ctx.strokeStyle = '#3c0a46'; ctx.lineWidth = jr * 0.08; ctx.lineCap = 'round';
    ctx.beginPath(); ctx.arc(0, jr * 0.22, jr * 0.3, 0.2 * Math.PI, 0.8 * Math.PI); ctx.stroke();
    ctx.restore();

    ctx.fillStyle = '#fff';
    ctx.font = `800 ${Math.round(Math.max(20, H * 0.04))}px "Segoe UI", system-ui, sans-serif`;
    ctx.textAlign = 'left';
    ctx.shadowColor = 'rgba(0,0,0,0.25)'; ctx.shadowBlur = 6;
    ctx.fillText(`${Math.floor(g.score)}`, 24, 44);
    ctx.font = `600 ${Math.round(Math.max(13, H * 0.022))}px "Segoe UI", system-ui, sans-serif`;
    ctx.fillText(`BEST ${best}   🪙 ${g.coins}`, 24, 72);
    ctx.textAlign = 'center';
    if (g.state !== 'play') {
      ctx.font = `900 ${Math.round(Math.max(34, H * 0.08))}px "Segoe UI", system-ui, sans-serif`;
      ctx.fillText(g.state === 'over' ? 'GAME OVER' : 'JELLY JUMP', W / 2, H * 0.45);
      ctx.font = `600 ${Math.round(Math.max(15, H * 0.028))}px "Segoe UI", system-ui, sans-serif`;
      ctx.fillText('Click or press Space to jump', W / 2, H * 0.45 + 42);
    }
    ctx.shadowBlur = 0;
  }

  function roundRect(x, y, w, h, r) {
    ctx.beginPath();
    ctx.moveTo(x + r, y); ctx.arcTo(x + w, y, x + w, y + h, r); ctx.arcTo(x + w, y + h, x, y + h, r);
    ctx.arcTo(x, y + h, x, y, r); ctx.arcTo(x, y, x + w, y, r); ctx.fill();
  }

  let last = performance.now();
  function frame(t) {
    const dt = Math.min(0.05, (t - last) / 1000);
    last = t;
    if (running) { update(dt); draw(); }
    requestAnimationFrame(frame);
  }
  requestAnimationFrame(frame);

  return {
    pause() { running = false; hold = null; },
    resume() { running = true; last = performance.now(); resize(); if (g.state === 'play') g.state = 'ready'; },
  };
}

module.exports = { startGame, HOLD_MS };
