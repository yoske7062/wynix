(() => {
  const reduce = matchMedia('(prefers-reduced-motion: reduce)').matches;
  const fine = matchMedia('(hover: hover)').matches;
  const $ = (s, r = document) => r.querySelector(s);
  const $$ = (s, r = document) => [...r.querySelectorAll(s)];

  // split text nodes into masked words, keep child elements (like the highlight) intact
  function splitWords(el) {
    const out = [];
    [...el.childNodes].forEach(n => {
      if (n.nodeType === 3) {
        const frag = document.createDocumentFragment();
        n.textContent.split(/(\s+)/).forEach(t => {
          if (!t) return;
          if (/^\s+$/.test(t)) { frag.append(t); return; }
          const m = document.createElement('span'); m.className = 'wm';
          const s = document.createElement('span'); s.textContent = t;
          m.append(s); frag.append(m); out.push(s);
        });
        n.replaceWith(frag);
      } else if (n.nodeType === 1) {
        const m = document.createElement('span'); m.className = 'wm';
        n.replaceWith(m); m.append(n); out.push(n);
      }
    });
    return out;
  }

  // marquee: duplicate track for seamless loop
  $$('.marquee .trk').forEach(t => t.innerHTML += t.innerHTML);

  // optimize panel extras
  const consPanel = $('.cons .panel');
  if (consPanel) {
    consPanel.insertAdjacentHTML('beforeend', '<div class="rail"><i></i></div><div class="flycover"></div>');
    $$('#engine .opt').forEach(o => {
      const small = o.querySelector('small');
      small.insertAdjacentHTML('beforeend', '<span class="ck"></span>');
    });
  }

  // tabs progress bars
  $$('.tab').forEach(t => t.insertAdjacentHTML('beforeend', '<span class="pb"></span>'));

  // wordmark letters
  const bm = $('.bigmark h2');
  if (bm) bm.innerHTML = bm.textContent.split('').map(c => `<span class="l">${c}</span>`).join('');

  if (!window.gsap) return;
  gsap.registerPlugin(ScrollTrigger);

  // smooth scroll
  if (window.Lenis && !reduce) {
    const lenis = new Lenis({ autoRaf: false, lerp: 0.1 });
    lenis.on('scroll', ScrollTrigger.update);
    gsap.ticker.add(t => lenis.raf(t * 1000));
    gsap.ticker.lagSmoothing(0);
    $$('a[href^="#"]').forEach(a => a.addEventListener('click', e => {
      const id = a.getAttribute('href');
      if (id.length > 1 && $(id)) { e.preventDefault(); lenis.scrollTo(id, { offset: -80 }); }
    }));
  }

  // nav hides on scroll down, shows on scroll up
  const nav = $('nav'); let lastY = 0;
  ScrollTrigger.create({ onUpdate: s => {
    const y = s.scroll();
    nav.classList.toggle('hide', y > 300 && y > lastY);
    lastY = y;
  }});

  // HERO intro
  const heroWords = splitWords($('.hero h1'));
  const intro = gsap.timeline({ defaults: { ease: 'expo.out' } });
  intro
    .from('.hero .panel', { scale: .96, borderRadius: 60, duration: 1.4 }, 0)
    .from(heroWords, { yPercent: 115, rotate: 4, duration: 1.2, stagger: .055 }, .15)
    .from('.icons span', { scale: 0, duration: .8, stagger: .08, ease: 'back.out(2)' }, .5)
    .from('.hside p', { y: 20, opacity: 0, duration: 1 }, .6)
    .from('.tile', { y: 120, opacity: 0, duration: 1.4, stagger: .1 }, .45)
    .from('.tile .mrow, .ctx div', { x: -16, opacity: 0, duration: .6, stagger: .04 }, 1.0);

  // hero tiles parallax at different speeds
  if (!reduce) $$('.tile > *').forEach((t, i) => {
    gsap.to(t, { y: (i % 2 ? -40 : -15), ease: 'none',
      scrollTrigger: { trigger: '.bento', start: 'top 70%', end: 'bottom top', scrub: true } });
  });

  // mockups tilt with mouse
  $$('.tile > *:not(.ctx)').forEach(el => el.classList.add('tilt'));
  if (fine && !reduce) $$('.tile').forEach(tile => {
    const inner = tile.querySelector('.tilt');
    if (!inner) return;
    const rx = gsap.quickTo(inner, 'rotationX', { duration: .6, ease: 'power3' });
    const ry = gsap.quickTo(inner, 'rotationY', { duration: .6, ease: 'power3' });
    tile.addEventListener('mousemove', e => {
      const r = tile.getBoundingClientRect();
      ry(((e.clientX - r.left) / r.width - .5) * 14);
      rx(-((e.clientY - r.top) / r.height - .5) * 14);
    });
    tile.addEventListener('mouseleave', () => { rx(0); ry(0); });
  });

  // hero photo: starts as a small inset card and grows to full width while the image zooms out
  gsap.fromTo('.heroimg', { clipPath: 'inset(0% 22% 18% 22% round 28px)' }, { clipPath: 'inset(0% 0% 0% 0% round 20px)', ease: 'none',
    scrollTrigger: { trigger: '.heroimg', start: 'top 85%', end: 'center 45%', scrub: true } });
  gsap.fromTo('.heroimg img', { scale: 1.25 }, { scale: 1, ease: 'none',
    scrollTrigger: { trigger: '.heroimg', start: 'top bottom', end: 'bottom top', scrub: true } });
  gsap.from('.heroimg figcaption', { y: 30, opacity: 0, duration: .8, ease: 'back.out(1.6)',
    scrollTrigger: { trigger: '.heroimg', start: 'center 70%' } });
  setInterval(() => { const f = document.getElementById('fpsHero'); if (f) f.textContent = (Math.random() > .85 ? 59 : 60) + ' FPS'; }, 900);

  // flatlay parallax + sticker pop
  gsap.fromTo('.flatimg img', { yPercent: -12 }, { yPercent: 0, ease: 'none',
    scrollTrigger: { trigger: '.flatimg', start: 'top bottom', end: 'bottom top', scrub: true } });
  gsap.from('.flatimg .q', { scale: 0, rotate: -20, duration: .9, ease: 'back.out(2)',
    scrollTrigger: { trigger: '.flatimg', start: 'center 75%' } });

  // covers: lift and tilt in when the features box arrives
  gsap.from('.fvis .cover', { y: 60, rotate: (i) => [-6, 0, 6][i % 3], opacity: 0, duration: 1, ease: 'expo.out', stagger: .08,
    scrollTrigger: { trigger: '.fbox', start: 'top 70%' } });

  // big wordmark letters rise
  gsap.from('.bigmark .l', { yPercent: 100, ease: 'none', stagger: .08,
    scrollTrigger: { trigger: '.bigmark', start: 'top bottom', end: 'bottom 85%', scrub: true } });
  gsap.from('.bigmark svg', { rotate: -90, scale: .4, ease: 'none',
    scrollTrigger: { trigger: '.bigmark', start: 'top bottom', end: 'bottom 85%', scrub: true } });

  // marquee speeds up with scroll velocity
  const trk = $('.marquee .trk');
  if (trk) ScrollTrigger.create({ trigger: '.marquee', start: 'top bottom', end: 'bottom top', onUpdate: s => {
    const v = Math.min(Math.abs(s.getVelocity()) / 400, 4);
    trk.style.animationDuration = (34 / (1 + v)) + 's';
  }});

  // benefits: words light up while scrolling
  $$('.words').forEach(p => gsap.to(p.querySelectorAll('.w'), { opacity: 1, stagger: .05, ease: 'none',
    scrollTrigger: { trigger: p, start: 'top 80%', end: 'bottom 45%', scrub: true } }));

  // stats: icons spin in, numbers count
  $$('.stat').forEach((s, i) => {
    const tl = gsap.timeline({ scrollTrigger: { trigger: s, start: 'top 88%' } });
    tl.from(s.querySelector('svg'), { rotate: -180, scale: 0, duration: 1, ease: 'back.out(1.8)', delay: i * .12 })
      .from(s.querySelector('h3'), { y: 30, opacity: 0, duration: .8, ease: 'power3.out' }, '<.15')
      .from(s.querySelector('p'), { y: 14, opacity: 0, duration: .6 }, '<.15');
    const c = s.querySelector('.count');
    if (c) { const o = { v: 0 }; c.textContent = '0';
      tl.to(o, { v: +c.dataset.to, duration: 1.4, ease: 'power2.out', onUpdate: () => c.textContent = Math.round(o.v) }, '<'); }
  });

  // section headings: masked word reveal
  $$('.h3, .cta h3').forEach(h => {
    const w = splitWords(h);
    gsap.from(w, { yPercent: 110, duration: 1, ease: 'expo.out', stagger: .05,
      scrollTrigger: { trigger: h, start: 'top 88%' } });
  });
  $$('.lbl').forEach(l => gsap.from(l, { x: -20, opacity: 0, duration: .8, ease: 'power3.out',
    scrollTrigger: { trigger: l, start: 'top 90%' } }));

  // OPTIMIZE: scroll drives words, engine choice, progress, cover flying into library
  const cw = $$('#consTitle .w');
  const opts = $$('#engine .opt');
  window.__engineManual = true;
  const consTl = gsap.timeline({ scrollTrigger: { trigger: '.cons .track', start: 'top 15%', end: 'bottom bottom', scrub: .6,
    onUpdate: s => {
      const n = Math.max(1, Math.ceil(s.progress * cw.length));
      cw.forEach((w, i) => w.classList.toggle('on', i < n));
      const e = Math.min(opts.length - 1, Math.floor(s.progress * opts.length));
      opts.forEach((o, i) => o.classList.toggle('on', i === e));
    } } });
  consTl.to('.rail i', { width: '100%', ease: 'none' }, 0)
    .fromTo('.engine', { rotate: -4, y: 40 }, { rotate: 0, y: 0, ease: 'none' }, 0)
    .to('.flycover', { left: '78%', top: '70%', scale: .35, rotate: 12, ease: 'power1.inOut' }, 0)
    .fromTo('.cons .panel', { backgroundColor: '#ECEBE8' }, { backgroundColor: '#E3E2DD', ease: 'none' }, 0);

  // FEATURES: tabs auto-advance with progress bar, pause on hover
  const tabs = $$('.tab');
  let cur = 0, prog;
  const go = i => {
    cur = i; tabs[i].click();
    tabs.forEach(t => gsap.set(t.querySelector('.pb'), { width: 0 }));
    prog && prog.kill();
    prog = gsap.to(tabs[i].querySelector('.pb'), { width: '100%', duration: 5, ease: 'none',
      onComplete: () => go((cur + 1) % tabs.length) });
  };
  tabs.forEach((t, i) => t.addEventListener('click', e => { if (e.isTrusted) go(i); }));
  ScrollTrigger.create({ trigger: '.fbox', start: 'top 80%', once: true, onEnter: () => go(0) });
  const fbox = $('.fbox');
  fbox.addEventListener('mouseenter', () => prog && prog.pause());
  fbox.addEventListener('mouseleave', () => prog && prog.resume());
  gsap.fromTo('.fbox', { clipPath: 'inset(12% 8% 12% 8% round 40px)' }, { clipPath: 'inset(0% 0% 0% 0% round 24px)', ease: 'none',
    scrollTrigger: { trigger: '.fbox', start: 'top bottom', end: 'top 40%', scrub: true } });

  // cards rise in a stagger
  ['.macs', '.plans'].forEach(g => gsap.from(`${g} > *`, { y: 80, opacity: 0, rotate: 2, duration: 1.1, ease: 'expo.out', stagger: .1,
    scrollTrigger: { trigger: g, start: 'top 85%' } }));
  gsap.from('.plan.mid', { scale: .92, ease: 'none', scrollTrigger: { trigger: '.plans', start: 'top bottom', end: 'center center', scrub: true } });
  gsap.from('details', { y: 20, opacity: 0, duration: .7, stagger: .07, ease: 'power3.out',
    scrollTrigger: { trigger: '#faq', start: 'top 80%' } });

  // CTA panel opens up from a small pill
  gsap.fromTo('.cta .panel', { clipPath: 'inset(30% 30% 30% 30% round 200px)' }, { clipPath: 'inset(0% 0% 0% 0% round 24px)', ease: 'none',
    scrollTrigger: { trigger: '.cta', start: 'top bottom', end: 'top 30%', scrub: true } });

  // magnetic buttons
  if (fine) $$('.go, .menu, .tab').forEach(b => {
    const x = gsap.quickTo(b, 'x', { duration: .5, ease: 'power3' });
    const y = gsap.quickTo(b, 'y', { duration: .5, ease: 'power3' });
    b.addEventListener('mousemove', e => {
      const r = b.getBoundingClientRect();
      x((e.clientX - r.left - r.width / 2) * .3); y((e.clientY - r.top - r.height / 2) * .3);
    });
    b.addEventListener('mouseleave', () => { x(0); y(0); });
  });

  // cursor dot
  if (fine) {
    const d = document.createElement('div'); d.className = 'cdot'; document.body.append(d);
    const cx = gsap.quickTo(d, 'left', { duration: .35, ease: 'power3' });
    const cy = gsap.quickTo(d, 'top', { duration: .35, ease: 'power3' });
    addEventListener('mousemove', e => { cx(e.clientX); cy(e.clientY); });
    $$('a, button, .tile, .mac, .plan').forEach(el => {
      el.addEventListener('mouseenter', () => d.classList.add('big'));
      el.addEventListener('mouseleave', () => d.classList.remove('big'));
    });
  }

  addEventListener('load', () => ScrollTrigger.refresh());
})();
