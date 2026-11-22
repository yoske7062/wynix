(() => {
  const nav = document.getElementById('nav');
  const sticky = document.getElementById('sticky');
  const end = document.getElementById('download');
  const onScroll = () => {
    nav.classList.toggle('s', scrollY > 8);
    const r = end.getBoundingClientRect();
    sticky.classList.toggle('h', scrollY < 500 || r.top < innerHeight);
  };
  addEventListener('scroll', onScroll, { passive: true }); onScroll();
  const trk = document.getElementById('trk');
  trk.innerHTML += trk.innerHTML;

  const copy = document.getElementById('copy');
  copy.addEventListener('click', async () => {
    try { await navigator.clipboard.writeText(document.getElementById('cmd').textContent); copy.textContent = 'Copied'; }
    catch { copy.textContent = 'Select and copy'; }
    setTimeout(() => copy.textContent = 'Copy', 1800);
  });

  // Download click: let the file download, then show the 3 install steps.
  const steps = document.getElementById('steps');
  document.querySelectorAll('.dl').forEach(a => a.addEventListener('click', () => {
    steps.classList.add('on');
    setTimeout(() => end.scrollIntoView({ behavior: 'smooth' }), 300);
  }));

  // App replica: sidebar switches views, buttons fake the real flows.
  const app = document.getElementById('banner');
  const show = v => {
    app.querySelectorAll('aside button').forEach(b => b.classList.toggle('on', b.dataset.v === v));
    app.querySelectorAll('.v').forEach(p => p.classList.toggle('on', p.dataset.p === v));
  };
  app.addEventListener('click', e => {
    const t = e.target.closest('[data-v],[data-go],button,.seg i');
    if (!t) return;
    const target = t.dataset.v || t.dataset.go;
    if (target && ['exe','new','opt','set'].includes(target)) {
      if (target !== 'set') show('home');
      app.querySelectorAll('.dim').forEach(d => d.classList.toggle('on', d.dataset.s === target));
      return;
    }
    if (t.matches('[data-close]')) { t.closest('.dim').classList.remove('on'); return; }
    if (t.matches('[data-pick]')) {
      const f = app.querySelector('[data-file]'); f.textContent = 'Notepad++ installer.exe'; f.classList.remove('mut2');
      app.querySelector('.dim[data-s=exe] .pri').disabled = false; return;
    }
    if (target) return show(target);
    if (t.matches('.seg i')) { t.parentNode.querySelectorAll('i').forEach(i => i.classList.toggle('on', i === t)); return; }
    if (t.textContent === 'Install') {
      t.textContent = 'Installing…';
      setTimeout(() => { t.textContent = 'Open'; t.classList.add('ok'); t.closest('.card').querySelector('em').textContent = 'Installed and ready'; }, 1400);
    } else if (t.textContent === 'Play') {
      t.textContent = 'Starting…'; setTimeout(() => t.textContent = 'Play', 1600);
    } else if (t.textContent === 'Create') {
      t.textContent = 'Created ✓'; setTimeout(() => t.textContent = 'Create', 1600);
    }
  });

  if (!window.gsap) return;
  gsap.registerPlugin(ScrollTrigger);
  const reduce = matchMedia('(prefers-reduced-motion: reduce)').matches;
  const ease = 'expo.out';
  const dy = reduce ? 0 : 1;

  if (window.Lenis && !reduce) {
    const lenis = new Lenis({ autoRaf: false, duration: 1.2 });
    lenis.on('scroll', ScrollTrigger.update);
    gsap.ticker.add(t => lenis.raf(t * 1000));
    gsap.ticker.lagSmoothing(0);
    document.querySelectorAll('a[href^="#"]').forEach(a => a.addEventListener('click', e => {
      const h = a.getAttribute('href');
      if (h.length > 1) { e.preventDefault(); lenis.scrollTo(h, { offset: -72 }); }
    }));
  }

  gsap.from('[data-in]', { y: 18 * dy, opacity: 0, filter: 'blur(6px)', duration: 1.4, ease, stagger: .1, delay: .1, clearProps: 'filter' });
  gsap.from('#banner', { y: 40 * dy, opacity: 0, duration: 1.6, ease, delay: .5 });

  gsap.utils.toArray('[data-up]').forEach(el => gsap.from(el, { y: 24 * dy, opacity: 0, duration: 1.3, ease,
    scrollTrigger: { trigger: el, start: 'top 88%', once: true } }));
  gsap.utils.toArray('[data-list]').forEach(l => gsap.from(l.children, { y: 16 * dy, opacity: 0, duration: 1.1, ease, stagger: .07,
    scrollTrigger: { trigger: l, start: 'top 85%', once: true } }));

})();
