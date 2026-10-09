/* HAYEVA — illustrations techniques animées (V4, direction « Flux »).
 *
 * Trois métiers, un motif commun : ce qui circule.
 *   Climatisation : l'air (bleu), Chauffage : la chaleur (orange),
 *   Plomberie : l'eau (bleu-vert).
 * Les SVG sont injectés dans tout élément [data-hv-illus="clim|chauffage|
 * plomberie|hero"] (y compris ceux créés plus tard par les espaces). Les
 * animations sont en CSS (transform / opacity / stroke-dashoffset) et ne
 * tournent que lorsque l'illustration est à l'écran (classe .is-live) et
 * que l'onglet est visible ; rien ne bouge en « réduire les animations ».
 * Purement décoratif : aria-hidden, aucun texte, aucune donnée.
 */
(function () {
  'use strict';
  var mq = window.matchMedia ? window.matchMedia('(prefers-reduced-motion: reduce)') : null;
  function reduced() { return !!(mq && mq.matches); }

  var SVG = {
    clim:
      '<svg viewBox="0 0 120 90" focusable="false">' +
        '<defs><radialGradient id="hvgClim" cx="50%" cy="45%" r="60%"><stop offset="0" stop-color="#DCEFFC"/><stop offset="1" stop-color="#DCEFFC" stop-opacity="0"/></radialGradient></defs>' +
        '<ellipse cx="60" cy="48" rx="56" ry="40" fill="url(#hvgClim)"/>' +
        '<g class="hvi-float">' +
          '<rect x="16" y="12" width="88" height="28" rx="8" fill="#FFFFFF" stroke="#1F5A8F" stroke-width="2.2"/>' +
          '<path d="M24 32h72" stroke="#1F5A8F" stroke-width="1.6" stroke-linecap="round" opacity=".5"/>' +
          '<path d="M26 36.5h68" stroke="#1F5A8F" stroke-width="1.6" stroke-linecap="round" opacity=".35"/>' +
          '<circle class="hvi-led" cx="94" cy="20" r="2.2" fill="#1AA6EE"/>' +
        '</g>' +
        '<g fill="none" stroke-linecap="round">' +
          '<path class="hvi-flow" d="M28 44c6 10 16 10 22 18s10 14 22 14" stroke="#1AA6EE" stroke-width="2.6"/>' +
          '<path class="hvi-flow hvi-d1" d="M48 44c4 9 14 9 20 16s10 12 22 12" stroke="#5CC2F2" stroke-width="2.2"/>' +
          '<path class="hvi-flow hvi-d2" d="M70 44c4 7 12 8 17 13s8 9 18 9" stroke="#9FD8F6" stroke-width="2"/>' +
        '</g>' +
        '<g fill="#1AA6EE"><circle class="hvi-spark" cx="40" cy="70" r="1.6"/><circle class="hvi-spark hvi-d1" cx="88" cy="60" r="1.3"/><circle class="hvi-spark hvi-d2" cx="62" cy="80" r="1.4"/></g>' +
      '</svg>',
    chauffage:
      '<svg viewBox="0 0 120 90" focusable="false">' +
        '<defs><radialGradient id="hvgHeat" cx="50%" cy="62%" r="58%"><stop offset="0" stop-color="#FFE2CC"/><stop offset="1" stop-color="#FFE2CC" stop-opacity="0"/></radialGradient></defs>' +
        '<ellipse class="hvi-glow" cx="60" cy="54" rx="54" ry="36" fill="url(#hvgHeat)"/>' +
        '<g fill="none" stroke-linecap="round" stroke-width="2.6">' +
          '<path class="hvi-rise" d="M38 34c-4-4 4-8 0-12s4-8 0-12" stroke="#E85A12"/>' +
          '<path class="hvi-rise hvi-d1" d="M60 32c-4-4 4-8 0-12s4-8 0-12" stroke="#F08A4B"/>' +
          '<path class="hvi-rise hvi-d2" d="M82 34c-4-4 4-8 0-12s4-8 0-12" stroke="#E85A12"/>' +
        '</g>' +
        '<g stroke="#C2410C" stroke-width="2" fill="#FFFFFF">' +
          '<rect x="24" y="42" width="12" height="36" rx="6"/><rect x="40" y="40" width="12" height="38" rx="6"/>' +
          '<rect x="56" y="40" width="12" height="38" rx="6"/><rect x="72" y="40" width="12" height="38" rx="6"/>' +
          '<rect x="88" y="42" width="12" height="36" rx="6"/>' +
        '</g>' +
        '<path d="M18 74h86" stroke="#C2410C" stroke-width="2.4" stroke-linecap="round"/>' +
        '<g fill="#F5B27A" opacity=".9"><rect x="28" y="50" width="4" height="20" rx="2"/><rect x="44" y="48" width="4" height="22" rx="2"/><rect x="60" y="48" width="4" height="22" rx="2"/><rect x="76" y="48" width="4" height="22" rx="2"/><rect x="92" y="50" width="4" height="20" rx="2"/></g>' +
      '</svg>',
    plomberie:
      '<svg viewBox="0 0 120 90" focusable="false">' +
        '<defs><radialGradient id="hvgWater" cx="50%" cy="55%" r="60%"><stop offset="0" stop-color="#D5F1F4"/><stop offset="1" stop-color="#D5F1F4" stop-opacity="0"/></radialGradient></defs>' +
        '<ellipse cx="60" cy="50" rx="56" ry="38" fill="url(#hvgWater)"/>' +
        '<path d="M10 64h34a10 10 0 0 0 10-10V30a8 8 0 0 1 8-8h22" fill="none" stroke="#205A8F" stroke-width="8" stroke-linecap="round" stroke-linejoin="round"/>' +
        '<path class="hvi-pipe" d="M10 64h34a10 10 0 0 0 10-10V30a8 8 0 0 1 8-8h22" fill="none" stroke="#7CD3E8" stroke-width="2.6" stroke-linecap="round" stroke-linejoin="round"/>' +
        '<path d="M84 18h10a6 6 0 0 1 6 6v6" fill="none" stroke="#205A8F" stroke-width="6" stroke-linecap="round"/>' +
        '<rect x="78" y="12" width="8" height="14" rx="3" fill="#205A8F"/>' +
        '<path class="hvi-drop" d="M100 36c-2.6 3.6-4 5.8-4 7.6a4 4 0 0 0 8 0c0-1.8-1.4-4-4-7.6z" fill="#1AA6EE"/>' +
        '<ellipse class="hvi-ripple" cx="100" cy="78" rx="10" ry="2.6" fill="none" stroke="#1AA6EE" stroke-width="1.6"/>' +
        '<path d="M86 80h28" stroke="#205A8F" stroke-width="2" stroke-linecap="round" opacity=".45"/>' +
      '</svg>',
    hero:
      '<svg viewBox="0 0 1200 500" preserveAspectRatio="xMidYMax slice" focusable="false">' +
        '<defs>' +
          '<linearGradient id="hvgAir" x1="0" x2="1"><stop offset="0" stop-color="#1AA6EE" stop-opacity="0"/><stop offset=".12" stop-color="#1AA6EE"/><stop offset=".3" stop-color="#1AA6EE" stop-opacity="0"/><stop offset=".72" stop-color="#5CC2F2" stop-opacity="0"/><stop offset=".88" stop-color="#5CC2F2"/><stop offset="1" stop-color="#BFE0F5" stop-opacity="0"/></linearGradient>' +
          '<linearGradient id="hvgFire" x1="0" y1="1" x2="0" y2="0"><stop offset="0" stop-color="#E85A12"/><stop offset="1" stop-color="#F5B27A" stop-opacity="0"/></linearGradient>' +
          '<linearGradient id="hvgAqua" x1="0" x2="1"><stop offset="0" stop-color="#0F8FA6" stop-opacity="0"/><stop offset=".4" stop-color="#2BB3C8"/><stop offset="1" stop-color="#2BB3C8" stop-opacity="0"/></linearGradient>' +
        '</defs>' +
        '<g class="hvh-layer hvh-l3"><g fill="none" stroke="url(#hvgAir)" stroke-linecap="round">' +
          '<path class="hvh-air" d="M-40 360C160 300 330 400 560 350S920 300 1240 340" stroke-width="2.4"/>' +
          '<path class="hvh-air hvi-d1" d="M-40 395C200 345 380 430 620 385S980 340 1240 380" stroke-width="1.8"/>' +
          '<path class="hvh-air hvi-d2" d="M-40 430C220 385 420 460 660 420S1000 380 1240 415" stroke-width="1.4"/>' +
        '</g></g>' +
        '<g class="hvh-layer hvh-l2"><g fill="none" stroke="url(#hvgFire)" stroke-linecap="round" stroke-width="3">' +
          '<path class="hvh-heat" d="M1010 500c-14-22 14-40 0-62s14-40 0-62"/>' +
          '<path class="hvh-heat hvi-d1" d="M1060 500c-14-22 14-40 0-62s14-40 0-62"/>' +
          '<path class="hvh-heat hvi-d2" d="M1110 500c-14-22 14-40 0-62s14-40 0-62"/>' +
          '<path class="hvh-heat hvi-d3" d="M140 500c-12-20 12-36 0-56s12-36 0-56"/>' +
        '</g></g>' +
        '<g class="hvh-layer hvh-l1"><g fill="none" stroke-linecap="round">' +
          '<path d="M-40 470C200 440 420 490 640 462S1000 430 1240 456" stroke="url(#hvgAqua)" stroke-width="3" opacity=".55"/>' +
          '<path class="hvh-water" d="M-40 470C200 440 420 490 640 462S1000 430 1240 456" stroke="#7CD3E8" stroke-width="2"/>' +
        '</g></g>' +
      '</svg>',
    // Composition portrait (téléphone) : les flux occupent le bas de l'écran
    // et les bords, jamais le centre où se trouvent le titre et les boutons.
    heroM:
      '<svg viewBox="0 0 400 600" preserveAspectRatio="xMidYMax slice" focusable="false">' +
        '<defs>' +
          '<linearGradient id="hvgAirM" x1="0" x2="1"><stop offset="0" stop-color="#1AA6EE" stop-opacity="0"/><stop offset=".3" stop-color="#1AA6EE"/><stop offset="1" stop-color="#BFE0F5" stop-opacity="0"/></linearGradient>' +
          '<linearGradient id="hvgFireM" x1="0" y1="1" x2="0" y2="0"><stop offset="0" stop-color="#E85A12"/><stop offset="1" stop-color="#F5B27A" stop-opacity="0"/></linearGradient>' +
        '</defs>' +
        '<g class="hvh-layer hvh-l3"><g fill="none" stroke="url(#hvgAirM)" stroke-linecap="round">' +
          '<path class="hvh-air" d="M-20 470C80 430 160 500 260 462S360 420 420 444" stroke-width="2"/>' +
          '<path class="hvh-air hvi-d1" d="M-20 505C90 470 170 530 270 496S370 460 420 480" stroke-width="1.6"/>' +
        '</g></g>' +
        '<g class="hvh-layer hvh-l2"><g fill="none" stroke="url(#hvgFireM)" stroke-linecap="round" stroke-width="2.6">' +
          '<path class="hvh-heat" d="M372 600c-10-16 10-30 0-46s10-30 0-46"/>' +
          '<path class="hvh-heat hvi-d1" d="M392 600c-10-16 10-30 0-46s10-30 0-46"/>' +
          '<path class="hvh-heat hvi-d2" d="M18 600c-10-16 10-30 0-46s10-30 0-46"/>' +
        '</g></g>' +
        '<g class="hvh-layer hvh-l1"><g fill="none" stroke-linecap="round">' +
          '<path class="hvh-water" d="M-20 580C90 556 180 596 280 572S380 552 420 566" stroke="#7CD3E8" stroke-width="2"/>' +
        '</g></g>' +
      '</svg>'
  };

  var io = typeof IntersectionObserver === 'function'
    ? new IntersectionObserver(function (entries) {
        entries.forEach(function (e) { e.target.classList.toggle('is-live', e.isIntersecting); });
      }, { rootMargin: '40px' })
    : null;

  function mount(el) {
    var kind = el.getAttribute('data-hv-illus');
    if (!SVG[kind] || el.hasAttribute('data-hv-m')) return;
    el.setAttribute('data-hv-m', '');
    el.setAttribute('aria-hidden', 'true');
    el.classList.add('hv-illus', 'hv-illus-' + kind);
    el.innerHTML = (kind === 'hero' && window.innerWidth < 760) ? SVG.heroM : SVG[kind];
    if (io) io.observe(el); else el.classList.add('is-live');
  }

  /* Cartes métiers du site public : l'illustration remplace la petite
     pastille d'icône (gardée en repli si ce script ne se charge pas). */
  function enhanceCards(root) {
    Array.prototype.forEach.call((root || document).querySelectorAll('.besoin-cat-btn[data-cat]:not(.has-illus)'), function (btn) {
      var cat = btn.getAttribute('data-cat');
      if (!SVG[cat]) return;
      var box = document.createElement('span');
      box.setAttribute('data-hv-illus', cat);
      btn.insertBefore(box, btn.firstChild);
      btn.classList.add('has-illus');
      mount(box);
    });
  }

  /* Cartes de formules côte à côte : les rangées badges / nom / accroche
     prennent la même hauteur dans une même ligne, pour que les prix soient
     alignés quelle que soit la longueur d'un badge. */
  var ROWS = ['.hvk-badges', '.hvk-name', '.hvk-tagline'];
  function alignPackGrids() {
    Array.prototype.forEach.call(document.querySelectorAll('.hvk-grid'), function (grid) {
      var cards = Array.prototype.filter.call(grid.children, function (c) { return c.classList && c.classList.contains('hvk-card'); });
      ROWS.forEach(function (sel) { cards.forEach(function (c) { var el = c.querySelector(sel); if (el) el.style.minHeight = ''; }); });
      if (cards.length < 2 || !cards[0].offsetWidth) return;
      var rows = {};
      cards.forEach(function (c) { var k = Math.round(c.offsetTop); (rows[k] = rows[k] || []).push(c); });
      Object.keys(rows).forEach(function (k) {
        var row = rows[k];
        if (row.length < 2) return;
        ROWS.forEach(function (sel) {
          var els = row.map(function (c) { return c.querySelector(sel); }).filter(Boolean);
          var h = Math.max.apply(null, els.map(function (e) { return e.offsetHeight; }));
          els.forEach(function (e) { e.style.minHeight = h + 'px'; });
        });
      });
    });
  }
  var alignT = 0;
  function alignSoon() { clearTimeout(alignT); alignT = setTimeout(alignPackGrids, 50); }
  window.addEventListener('resize', alignSoon);
  // Un groupe de tarifs devient visible après un choix de catégorie.
  document.addEventListener('click', function (e) { if (e.target.closest && e.target.closest('.price-logo-btn, .besoin-cat-btn, .ecx-fam-tab')) setTimeout(alignSoon, 30); });

  function scan() {
    alignSoon();
    enhanceCards(document);
    Array.prototype.forEach.call(document.querySelectorAll('[data-hv-illus]:not([data-hv-m])'), mount);
  }

  /* Sélection d'une carte métier : mise en valeur nette et persistante. */
  document.addEventListener('click', function (e) {
    var btn = e.target.closest ? e.target.closest('.besoin-cat-btn') : null;
    if (!btn) return;
    Array.prototype.forEach.call(document.querySelectorAll('.besoin-cat-btn.is-selected'), function (b) { b.classList.remove('is-selected'); b.removeAttribute('aria-pressed'); });
    btn.classList.add('is-selected');
    btn.setAttribute('aria-pressed', 'true');
  });

  /* ---------- Accueil : séquence d'arrivée + profondeur ---------- */
  var root = document.documentElement;
  function splitTitle() {
    if (!root.classList.contains('hv-intro')) return;
    Array.prototype.forEach.call(document.querySelectorAll('.hero [data-audience] h1, .hero [data-audience] h2'), function (h) {
      if (h.hasAttribute('data-hv-split') || h.children.length) return;
      var words = h.textContent.trim().split(/\s+/);
      h.setAttribute('data-hv-split', '');
      h.innerHTML = words.map(function (w, i) {
        return '<span class="hv-w"><span style="--i:' + i + '">' + w.replace(/[&<>]/g, function (c) { return { '&': '&amp;', '<': '&lt;', '>': '&gt;' }[c]; }) + '</span></span>';
      }).join(' ');
    });
  }
  function playIntro() { root.classList.add('hv-intro-go'); }
  function armIntro() {
    if (!root.classList.contains('hv-intro') && !root.classList.contains('hv-intro-quick')) return;
    splitTitle();
    var portal = document.getElementById('sitePortal');
    var covered = function () { return portal && !portal.hidden && !portal.classList.contains('is-leaving'); };
    if (!covered()) { playIntro(); return; }
    var mo = new MutationObserver(function () { if (!covered()) { mo.disconnect(); playIntro(); } });
    mo.observe(portal, { attributes: true, attributeFilter: ['hidden', 'class'] });
  }

  // Légère profondeur : les trois couches du visuel « Flux » se décalent
  // à des vitesses différentes au défilement (et au pointeur sur ordinateur).
  function parallax() {
    var hero = document.querySelector('.hero-flux');
    if (!hero || reduced()) return;
    var layers = hero.querySelectorAll('.hvh-layer');
    if (!layers.length) return;
    var K = [0.16, 0.09, 0.04], px = 0, py = 0, ticking = false;
    function paint() {
      ticking = false;
      if (!hero.classList.contains('is-live')) return;
      var y = Math.min(window.scrollY, 900);
      for (var i = 0; i < layers.length; i++) {
        layers[i].style.transform = 'translate3d(' + (px * (i + 1) * 3).toFixed(1) + 'px,' + (-y * K[i] + py * (i + 1) * 2).toFixed(1) + 'px,0)';
      }
    }
    function req() { if (!ticking) { ticking = true; requestAnimationFrame(paint); } }
    window.addEventListener('scroll', req, { passive: true });
    if (window.matchMedia('(pointer:fine)').matches) {
      hero.parentNode.addEventListener('pointermove', function (e) {
        var r = hero.getBoundingClientRect();
        px = ((e.clientX - r.left) / r.width - 0.5) * 2; py = ((e.clientY - r.top) / r.height - 0.5) * 2; req();
      }, { passive: true });
    }
  }

  /* Effets décoratifs anciens et nouveaux : suspendus quand leur section
     est hors écran (hors espaces connectés, qui gèrent leurs propres vues). */
  function pauseOffscreenSections() {
    if (typeof IntersectionObserver !== 'function') return;
    var so = new IntersectionObserver(function (entries) {
      entries.forEach(function (e) { e.target.classList.toggle('hv-offscreen', !e.isIntersecting); });
    }, { rootMargin: '120px 0px' });
    Array.prototype.forEach.call(document.querySelectorAll('body section, body footer'), function (sec) {
      if (sec.closest('#espaceClient, #espacePro, #sitePortal, .hvk-modal, .hvp-modal')) return;
      if (sec.parentNode && sec.parentNode.closest && sec.parentNode.closest('section')) return;
      so.observe(sec);
    });
  }

  function boot() {
    pauseOffscreenSections();
    scan();
    armIntro();
    parallax();
    if (typeof MutationObserver === 'function') {
      var pending = false;
      new MutationObserver(function () {
        if (pending) return;
        pending = true;
        requestAnimationFrame(function () { pending = false; scan(); });
      }).observe(document.body, { childList: true, subtree: true });
    }
    document.addEventListener('visibilitychange', function () { root.classList.toggle('hv-tab-hidden', document.hidden); });
  }
  window.HvIllus = { svg: function (k) { return SVG[k] || ''; }, scan: scan };
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', boot); else boot();
})();
