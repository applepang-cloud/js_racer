// Procedural engine + SFX for JS Racer, built on the Web Audio API.
// Exposed as global functions called from Dart via js_interop.
(function () {
  let ctx = null;
  let started = false;
  let master = null;
  let engineGain = null;
  let lowpass = null;
  let oscA = null, oscB = null, oscSub = null;
  let noiseSrc = null, noiseGain = null, noiseFilter = null;
  let curRpm = 0;

  function makeNoiseBuffer() {
    const len = ctx.sampleRate * 2;
    const buf = ctx.createBuffer(1, len, ctx.sampleRate);
    const data = buf.getChannelData(0);
    for (let i = 0; i < len; i++) data[i] = Math.random() * 2 - 1;
    return buf;
  }

  window.__engineStart = function () {
    if (started) {
      if (ctx && ctx.state === 'suspended') ctx.resume();
      return;
    }
    const AC = window.AudioContext || window.webkitAudioContext;
    if (!AC) return;
    ctx = new AC();

    master = ctx.createGain();
    master.gain.value = 0.55;
    master.connect(ctx.destination);

    // --- engine tone chain ---
    lowpass = ctx.createBiquadFilter();
    lowpass.type = 'lowpass';
    lowpass.frequency.value = 700;
    lowpass.Q.value = 6;

    engineGain = ctx.createGain();
    engineGain.gain.value = 0.0;
    lowpass.connect(engineGain);
    engineGain.connect(master);

    oscSub = ctx.createOscillator();
    oscSub.type = 'square';
    oscA = ctx.createOscillator();
    oscA.type = 'sawtooth';
    oscB = ctx.createOscillator();
    oscB.type = 'sawtooth';
    oscB.detune.value = 14;

    oscSub.connect(lowpass);
    oscA.connect(lowpass);
    oscB.connect(lowpass);
    oscSub.start();
    oscA.start();
    oscB.start();

    // --- offroad / tyre noise chain ---
    noiseFilter = ctx.createBiquadFilter();
    noiseFilter.type = 'bandpass';
    noiseFilter.frequency.value = 1200;
    noiseGain = ctx.createGain();
    noiseGain.gain.value = 0.0;
    noiseSrc = ctx.createBufferSource();
    noiseSrc.buffer = makeNoiseBuffer();
    noiseSrc.loop = true;
    noiseSrc.connect(noiseFilter);
    noiseFilter.connect(noiseGain);
    noiseGain.connect(master);
    noiseSrc.start();

    started = true;
    __engineSetRpm(0);
  };

  window.__engineSetRpm = function (rpm) {
    if (!started || !ctx) return;
    curRpm = rpm;
    const now = ctx.currentTime;
    const base = 55 + rpm * 230;          // fundamental
    oscSub.frequency.setTargetAtTime(base * 0.5, now, 0.03);
    oscA.frequency.setTargetAtTime(base, now, 0.03);
    oscB.frequency.setTargetAtTime(base, now, 0.03);
    lowpass.frequency.setTargetAtTime(500 + rpm * 2600, now, 0.05);
    // idle hum even at 0, louder with throttle (kept quieter so music leads)
    engineGain.gain.setTargetAtTime(0.06 + rpm * 0.28, now, 0.05);
  };

  window.__engineOffroad = function (on) {
    if (!started || !ctx) return;
    const now = ctx.currentTime;
    noiseGain.gain.setTargetAtTime(on ? 0.18 + curRpm * 0.25 : 0.0, now, 0.04);
  };

  window.__engineCrash = function () {
    if (!started || !ctx) return;
    const now = ctx.currentTime;
    const g = ctx.createGain();
    g.gain.setValueAtTime(0.0, now);
    g.gain.linearRampToValueAtTime(0.6, now + 0.01);
    g.gain.exponentialRampToValueAtTime(0.001, now + 0.45);
    const f = ctx.createBiquadFilter();
    f.type = 'lowpass';
    f.frequency.setValueAtTime(1800, now);
    f.frequency.exponentialRampToValueAtTime(120, now + 0.45);
    const n = ctx.createBufferSource();
    n.buffer = makeNoiseBuffer();
    n.connect(f); f.connect(g); g.connect(master);
    n.start(now); n.stop(now + 0.46);
  };

  window.__engineStop = function () {
    if (ctx && ctx.state === 'running') ctx.suspend();
  };

  // --- short musical SFX (oscillator blips) ---
  function blip(freq, start, dur, type, peak) {
    if (!started || !ctx) return;
    const t0 = ctx.currentTime + start;
    const o = ctx.createOscillator();
    const g = ctx.createGain();
    o.type = type || 'square';
    o.frequency.value = freq;
    g.gain.setValueAtTime(0.0001, t0);
    g.gain.exponentialRampToValueAtTime(peak || 0.3, t0 + 0.01);
    g.gain.exponentialRampToValueAtTime(0.0001, t0 + dur);
    o.connect(g); g.connect(master);
    o.start(t0); o.stop(t0 + dur + 0.02);
  }

  window.__sfxCheckpoint = function () {
    blip(880, 0, 0.12, 'square', 0.3);
    blip(1320, 0.1, 0.16, 'square', 0.3);
  };

  window.__sfxFinish = function () {
    blip(660, 0, 0.15, 'square', 0.35);
    blip(880, 0.14, 0.15, 'square', 0.35);
    blip(1320, 0.28, 0.30, 'square', 0.35);
  };

  window.__sfxGameOver = function () {
    blip(440, 0, 0.25, 'sawtooth', 0.3);
    blip(330, 0.22, 0.25, 'sawtooth', 0.3);
    blip(220, 0.44, 0.45, 'sawtooth', 0.3);
  };

  // --- background music (original racer.mp3) ---
  let music = null;
  window.__musicPlay = function (url) {
    if (!music) {
      music = new Audio(url);
      music.loop = true;
      music.volume = 0.5;
    }
    const p = music.play();
    if (p && p.catch) p.catch(function () {});
  };
  window.__musicSetMuted = function (m) {
    if (music) music.muted = !!m;
  };
})();
