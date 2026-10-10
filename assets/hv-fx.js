/* HAYEVA — module d'animations commun (V4, lot 1).
 *
 * S'appuie sur vendor/hayeva-motion-14.0.0.min.js (global HvMotion :
 * animate WAAPI, stagger, inView). Principes :
 *  - uniquement opacity et transform (pas de reflow) ;
 *  - rien si l'utilisateur a demandé « réduire les animations » ;
 *  - jamais de contenu laissé invisible : en cas d'échec ou à la fin de
 *    l'animation, les styles inline sont retirés ;
 *  - une seule animation par élément (WeakSet), pas de ré-animation quand
 *    une liste est simplement rafraîchie après coup.
 * Expose window.HvFx = { reduced, reveal, count, success, error }.
 */
(function () {
  'use strict';
  var M = window.HvMotion;
  var mq = window.matchMedia ? window.matchMedia('(prefers-reduced-motion: reduce)') : null;
  var EASE = [0.22, 1, 0.36, 1];
  var seen = typeof WeakSet === 'function' ? new WeakSet() : null;

  function reduced() { return !M || !M.animate || !!(mq && mq.matches); }
  function toList(t) {
    if (!t) return [];
    if (typeof t === 'string') return Array.prototype.slice.call(document.querySelectorAll(t));
    if (t.nodeType === 1) return [t];
    return Array.prototype.slice.call(t);
  }
  function clean(list) {
    list.forEach(function (el) { el.style.removeProperty('opacity'); el.style.removeProperty('transform'); });
  }
  function visible(el) { return el.offsetWidth > 0 || el.offsetHeight > 0; }

  /* Apparition en cascade (fade + translation verticale). */
  function reveal(target, o) {
    o = o || {};
    var list = toList(target).filter(function (el) {
      if (seen && seen.has(el)) return false;
      if (seen) seen.add(el);
      return visible(el);
    }).slice(0, o.max || 14);
    if (!list.length || reduced()) { clean(list); return Promise.resolve(); }
    var y = o.y == null ? 12 : o.y;
    try {
      var ctl = M.animate(list,
        { opacity: [0, 1], transform: ['translateY(' + y + 'px)', 'translateY(0px)'] },
        { duration: o.duration || 0.24, ease: EASE, delay: M.stagger(o.stagger == null ? 0.045 : o.stagger, { startDelay: o.startDelay || 0 }) });
      var done = function () { clean(list); };
      return Promise.resolve(ctl && ctl.finished).then(done, done);
    } catch (e) { clean(list); return Promise.resolve(); }
  }

  /* Compteur animé, une seule fois par élément ; la valeur finale est
     toujours celle fournie (jamais d'arrondi inventé). */
  function count(el, to, o) {
    o = o || {};
    if (!el) return;
    var fmt = o.format || function (n) { return String(Math.round(n)); };
    if (reduced() || !(to > 0) || el.__hvCounted) { el.textContent = fmt(to); return; }
    el.__hvCounted = true;
    var dur = (o.duration || 0.6) * 1000, t0 = null;
    function step(t) {
      if (t0 === null) t0 = t;
      var k = Math.min(1, (t - t0) / dur), e = 1 - Math.pow(1 - k, 3);
      el.textContent = k < 1 ? fmt(to * e) : fmt(to);
      if (k < 1) requestAnimationFrame(step);
    }
    requestAnimationFrame(step);
  }

  /* Confirmation (léger rebond) — à n'appeler qu'après réponse réelle du serveur. */
  function success(el) {
    if (!el || reduced()) return;
    try { M.animate(el, { transform: ['scale(0.96)', 'scale(1.02)', 'scale(1)'] }, { duration: 0.32, ease: EASE }).finished.then(function () { clean([el]); }, function () { clean([el]); }); } catch (e) { clean([el]); }
  }
  /* Erreur (secousse horizontale courte). */
  function error(el) {
    if (!el || reduced()) return;
    try { M.animate(el, { transform: ['translateX(0px)', 'translateX(-6px)', 'translateX(5px)', 'translateX(-3px)', 'translateX(0px)'] }, { duration: 0.3 }).finished.then(function () { clean([el]); }, function () { clean([el]); }); } catch (e) { clean([el]); }
  }

  /* Réglages de rythme communs (lus dans les jetons CSS --hv-t-*) :
     t('press') ≈ 140 ms, t('state') ≈ 260 ms, t('open') ≈ 440 ms,
     t('close') ≈ 240 ms. Une seule source de vérité pour CSS et JS. */
  var tCache = {};
  function t(name, fallback) {
    if (reduced()) return 0;
    if (tCache[name] == null) {
      var v = getComputedStyle(document.documentElement).getPropertyValue('--hv-t-' + name).trim();
      tCache[name] = v ? (parseFloat(v) * (/ms$/.test(v) ? 1 : 1000)) : null;
    }
    return tCache[name] == null ? fallback : tCache[name];
  }

  /* Message bref (« toast ») : n'est appelé qu'APRÈS la réponse réelle du
     serveur. Un nouveau message remplace le précédent sans empilement. */
  var toastEl = null, toastTimer = 0;
  function toast(msg, kind) {
    if (!toastEl) {
      toastEl = document.createElement('div');
      toastEl.className = 'hv-toast';
      toastEl.setAttribute('role', 'status');
      toastEl.setAttribute('aria-live', 'polite');
      document.body.appendChild(toastEl);
    }
    clearTimeout(toastTimer);
    toastEl.className = 'hv-toast is-' + (kind || 'success');
    toastEl.innerHTML = '<span class="hv-toast-icon" aria-hidden="true"></span><span class="hv-toast-text"></span>';
    toastEl.querySelector('.hv-toast-text').textContent = msg;
    toastEl.classList.remove('is-shown'); void toastEl.offsetWidth; toastEl.classList.add('is-shown');
    toastTimer = setTimeout(function () { toastEl.classList.remove('is-shown'); }, 3200);
  }
  window.hvToast = toast;

  window.HvFx = { reduced: reduced, reveal: reveal, count: count, success: success, error: error, t: t, toast: toast };
  if (!M || !M.animate) return;
  document.documentElement.classList.add('hv-fx');

  /* ---------- Espaces : cascade des blocs à l'ouverture d'un onglet ----------
     Un onglet (ec-panel / pro-page / adm-page) qui devient visible est
     « armé » 900 ms : ses blocs de premier niveau rendus pendant ce délai
     apparaissent en cascade. Après, un rafraîchissement de données
     remplace le contenu sans animation (pas de clignotement). */
  var PANELS = '.ec-panel, .pro-page, .adm-page';
  var GRIDS = '.ecx-svc-scroll, .pro-stats-grid, .adm-stats-grid, .pro-quicklinks, .adm-quicklinks';
  var armed = typeof WeakMap === 'function' ? new WeakMap() : null;
  function blocksOf(panel) {
    var out = [];
    Array.prototype.forEach.call(panel.children, function (c) {
      if (c.matches && c.matches(GRIDS)) Array.prototype.push.apply(out, c.children); else out.push(c);
    });
    return out;
  }
  function onShow(panel) {
    if (!armed || panel.hidden || !visible(panel)) return;
    armed.set(panel, Date.now() + 900);
    reveal(blocksOf(panel));
  }
  function bootPanels() {
    if (!armed || typeof MutationObserver !== 'function') return;
    var mo = new MutationObserver(function (records) {
      records.forEach(function (r) {
        var p = r.target;
        if (p.hidden) return;
        if (r.type === 'attributes') onShow(p);
        else if ((armed.get(p) || 0) > Date.now()) reveal(blocksOf(p));
      });
    });
    Array.prototype.forEach.call(document.querySelectorAll(PANELS), function (p) {
      mo.observe(p, { attributes: true, attributeFilter: ['hidden'], childList: true });
    });
    /* Ouverture d'un espace : l'onglet déjà visible est armé à son tour. */
    var shells = document.querySelectorAll('#espaceClient, #espacePro, #espaceProAdminPanel');
    var mo2 = new MutationObserver(function () {
      Array.prototype.forEach.call(document.querySelectorAll(PANELS), function (p) {
        if (!p.hidden && visible(p) && !armed.has(p)) onShow(p);
      });
    });
    Array.prototype.forEach.call(shells, function (s) { mo2.observe(s, { attributes: true, attributeFilter: ['class', 'hidden'] }); });
  }

  /* ---------- Site public : titres de section à l'entrée dans l'écran ----------
     Seuls les éléments situés sous la ligne de flottaison au chargement
     sont préparés (aucun contenu déjà affiché ne disparaît). */
  function bootPublic() {
    if (reduced() || !M.inView) return;
    var vh = window.innerHeight;
    toList('main .section-head, [data-hv-reveal]').forEach(function (el) {
      if (el.closest('#espaceClient, #espacePro, [hidden]')) return;
      if (el.getBoundingClientRect().top < vh) return;
      el.style.opacity = '0';
      M.inView(el, function () { if (seen) seen.delete(el); reveal(el, { y: 16, duration: 0.32 }); }, { margin: '0px 0px -8% 0px' });
    });
  }

  /* ---------- Indicateur animé de l'onglet actif ----------
     Une pastille unique glisse sous l'élément actif (barres de navigation,
     onglets de famille, filtres segmentés, périodes du planning). Repli
     sans script : le style .is-active d'origine reste en place. */
  var IND = [
    ['#ecxBottomNav', '.ecx-bottomnav-item', 'bar'],
    ['#hvBottomNav, .hv-bottomnav', '.hv-bottomnav-item', 'bar'],
    ['#ecxFamTabs', '.ecx-fam-tab', 'pill'],
    ['.ecx-seg', '.ecx-seg-btn', 'pill'],
    ['#hvpPlanViewSeg', 'button', 'pill'],
    ['#adminBkViewToggle', '.admin-bk-view-tab', 'pill']
  ];
  function placeInd(c) {
    var ind = c.__hvInd, act = null;
    var items = c.querySelectorAll(c.__hvItemSel);
    for (var i = 0; i < items.length; i++) if (items[i].classList.contains('is-active')) { act = items[i]; break; }
    if (!act || !act.offsetWidth) { ind.style.opacity = '0'; return; }
    var first = !ind.__placed;
    if (first) ind.style.transition = 'none';
    ind.style.width = act.offsetWidth + 'px';
    ind.style.height = act.offsetHeight + 'px';
    ind.style.transform = 'translate(' + act.offsetLeft + 'px,' + act.offsetTop + 'px)';
    ind.style.opacity = '1';
    if (first) { ind.__placed = true; void ind.offsetWidth; ind.style.transition = ''; }
  }
  function attachInd(c, itemSel, kind) {
    if (c.__hvInd) return;
    var ind = document.createElement('span');
    ind.className = 'hv-ind hv-ind-' + kind;
    ind.setAttribute('aria-hidden', 'true');
    c.__hvInd = ind; c.__hvItemSel = itemSel;
    c.insertBefore(ind, c.firstChild);
    c.classList.add('hv-ind-on');
    var raf = 0;
    var upd = function () { cancelAnimationFrame(raf); raf = requestAnimationFrame(function () { placeInd(c); }); };
    new MutationObserver(upd).observe(c, { attributes: true, attributeFilter: ['class'], subtree: true });
    window.addEventListener('resize', upd);
    c.__hvUpd = upd;
    upd();
  }
  function scanInd() {
    IND.forEach(function (d) {
      Array.prototype.forEach.call(document.querySelectorAll(d[0]), function (c) { attachInd(c, d[1], d[2]); });
    });
    // Conteneurs devenus visibles (espace ouvert, onglet affiché) : recalage.
    Array.prototype.forEach.call(document.querySelectorAll('.hv-ind-on'), function (c) { if (c.__hvInd && c.__hvInd.style.opacity !== '1') c.__hvUpd(); });
  }

  /* ---------- Sens des transitions entre vues ----------
     Aller vers un onglet situé plus à droite fait glisser la nouvelle vue
     depuis la droite, et inversement (léger déplacement + fondu). */
  var NAV_ITEMS = '.ecx-bottomnav-item, .hv-bottomnav-item, .ec-tab, .pro-nav-btn, .adm-nav-btn, .ecx-fam-tab, [data-ecx-subnav]';
  document.addEventListener('click', function (e) {
    var it = e.target.closest ? e.target.closest(NAV_ITEMS) : null;
    if (!it || !it.parentNode) return;
    var sibs = Array.prototype.slice.call(it.parentNode.children).filter(function (x) { return x.matches && x.matches(NAV_ITEMS); });
    var cur = -1;
    sibs.forEach(function (x, i) { if (x.classList.contains('is-active')) cur = i; });
    var to = sibs.indexOf(it);
    document.documentElement.style.setProperty('--hv-view-dx', (cur < 0 || to === cur) ? '0px' : (to > cur ? '18px' : '-18px'));
  }, true);

  /* iOS n'applique :active au toucher qu'avec un écouteur touchstart :
     indispensable pour la réponse visuelle immédiate à l'appui. */
  document.addEventListener('touchstart', function () {}, { passive: true });

  /* ---------- Planning (administration) ----------
     Changement de jour / semaine / mois demandé par l'utilisateur : les
     rendez-vous apparaissent en cascade très courte (≤ 0,3 s au total).
     Une actualisation automatique (temps réel) ne rejoue rien. */
  var lastUserAct = 0;
  document.addEventListener('pointerdown', function () { lastUserAct = Date.now(); }, true);
  document.addEventListener('keydown', function () { lastUserAct = Date.now(); }, true);
  function bootPlanning() {
    var pl = document.getElementById('adminBkPlanning');
    if (!pl || typeof MutationObserver !== 'function') return;
    new MutationObserver(function () {
      if (Date.now() - lastUserAct > 900) return;
      var items = pl.querySelectorAll('.hvp-card, .hvp-mcell, .hvp-empty');
      if (seen) Array.prototype.forEach.call(items, function (x) { seen.delete(x); });
      reveal(items, { y: 6, max: 14, stagger: 0.012, duration: 0.18 });
    }).observe(pl, { childList: true });
  }

  /* =================== HAYEVA SIGNATURE V5 =================== */

  /* Un seul écouteur de défilement (passif) pour tout le site public :
     en-tête posé, progression de lecture, parallaxe légère des vraies
     photos visibles, assistant qui s'efface pendant le défilement. */
  var header = null, progress = null, frames = [], tucks = [], tuckT = 0, lastY = 0, ticking = false;
  function espaceOpen() { return document.body.classList.contains('espace-overlay-lock'); }
  function onScrollFrame() {
    ticking = false;
    var y = window.scrollY || 0, vh = window.innerHeight;
    if (header) header.classList.toggle('hv-scrolled', y > 8);
    if (progress && !espaceOpen()) {
      var max = Math.max(1, document.documentElement.scrollHeight - vh);
      progress.style.transform = 'scaleX(' + Math.min(1, y / max).toFixed(4) + ')';
    }
    if (!reduced()) {
      for (var i = 0; i < frames.length; i++) {
        var f = frames[i];
        if (!f.__vis) continue;
        var r = f.getBoundingClientRect();
        var off = ((r.top + r.height / 2) - vh / 2) * -0.06;
        f.style.setProperty('--sig-par', Math.max(-16, Math.min(16, off)).toFixed(1) + 'px');
      }
    }
    // Assistant : s'efface quand on descend, revient dès l'arrêt.
    var down = y > lastY + 4;
    lastY = y;
    if (down && !reduced()) {
      tucks.forEach(function (b) { b.classList.add('hv-tucked'); });
      clearTimeout(tuckT);
      tuckT = setTimeout(function () { tucks.forEach(function (b) { b.classList.remove('hv-tucked'); }); }, 700);
    }
  }
  function requestFrame() { if (!ticking) { ticking = true; requestAnimationFrame(onScrollFrame); } }
  function bootScroll() {
    header = document.querySelector('body > header, header');
    progress = document.createElement('div');
    progress.className = 'hv-progress';
    progress.setAttribute('aria-hidden', 'true');
    document.body.appendChild(progress);
    frames = Array.prototype.slice.call(document.querySelectorAll('.photo-frame'));
    if (typeof IntersectionObserver === 'function') {
      var fo = new IntersectionObserver(function (es) { es.forEach(function (e) { e.target.__vis = e.isIntersecting; }); requestFrame(); });
      frames.forEach(function (f) { fo.observe(f); });
    }
    tucks = Array.prototype.slice.call(document.querySelectorAll('.ai-widget-toggle'));
    window.addEventListener('scroll', requestFrame, { passive: true });
    // Les espaces (plein écran) ont leur propre zone de défilement.
    Array.prototype.forEach.call(document.querySelectorAll('#espaceClient, #espacePro'), function (sec) {
      var ly = 0, t = 0;
      sec.addEventListener('scroll', function () {
        var y = sec.scrollTop, btns = sec.querySelectorAll('.ecx-assist-btn, .ecx-assist-callout');
        if (y > ly + 4 && !reduced()) {
          Array.prototype.forEach.call(btns, function (b) { b.classList.add('hv-tucked'); });
          clearTimeout(t);
          t = setTimeout(function () { Array.prototype.forEach.call(btns, function (b) { b.classList.remove('hv-tucked'); }); }, 700);
        }
        ly = y;
      }, { passive: true });
    });
    requestFrame();
  }

  /* Statistiques réelles : à leur première apparition, le chiffre compte
     brièvement jusqu'à la valeur reçue du serveur (format conservé à
     l'identique, valeur finale exacte). Une valeur qui change ensuite est
     simplement signalée, sans recompter. Rien n'est inventé : seuls les
     textes déjà numériques sont animés. */
  var COUNT_SEL = '.adm-stat-value, .pro-stat-value, .ec-amb-stat-value, .hvp-todo-item strong, .admin-bk-dash-value, [data-hv-count]';
  var counted = {};
  function keyOf(el) {
    var host = el.closest('[id]');
    var list = host ? host.querySelectorAll(COUNT_SEL) : [];
    return (el.id || (host ? host.id : '')) + ':' + Array.prototype.indexOf.call(list, el);
  }
  function parseNum(txt) {
    var m = /^(\D*?)(\d(?:[\d\s  ]*\d)?(?:,\d+)?)(\D*)$/.exec(String(txt).trim());
    if (!m) return null;
    var dec = (m[2].split(',')[1] || '').length;
    var v = parseFloat(m[2].replace(/[\s  ]/g, '').replace(',', '.'));
    return isNaN(v) ? null : { v: v, dec: dec, pre: m[1], post: m[3] };
  }
  function runCount(el, final) {
    var p = parseNum(final);
    if (!p || p.v <= 0 || reduced()) return;
    var t0 = null, dur = 650;
    el.__hvCounting = true;
    var fmt = function (n) { return p.pre + n.toLocaleString('fr-FR', { minimumFractionDigits: p.dec, maximumFractionDigits: p.dec }) + p.post; };
    function step(t) {
      if (!el.__hvCounting) return;
      if (t0 === null) t0 = t;
      var k = Math.min(1, (t - t0) / dur), e = 1 - Math.pow(1 - k, 3);
      if (k < 1) { el.__hvWritten = fmt(p.v * e); el.textContent = el.__hvWritten; requestAnimationFrame(step); }
      else { el.__hvWritten = final; el.textContent = final; el.__hvCounting = false; }
    }
    requestAnimationFrame(step);
  }
  // Indicateur à zéro : sa carte est atténuée (Black Signature), d'après la
  // valeur réellement écrite par l'application, jamais pendant le comptage.
  var ZERO_HOST = '.adm-stat-card, .pro-stat-card, .hvp-todo-item, .ec-amb-stat, .admin-bk-dash-card, [data-hv-count]';
  function markZero(el) {
    var host = el.closest(ZERO_HOST) || el, p = parseNum(el.textContent);
    host.classList.toggle('is-zero', !!p && p.v === 0);
  }
  function watchCount(el) {
    if (el.__hvCountBound) return;
    el.__hvCountBound = true;
    markZero(el);
    var check = function () {
      if (el.__hvCounting) return;
      var txt = el.textContent, p = parseNum(txt);
      if (!p) return;
      var k = keyOf(el);
      // Le comptage attend que le chiffre soit réellement à l'écran.
      if (!(k in counted)) { if (!el.__hvVis) return; counted[k] = txt; runCount(el, txt); }
      else if (counted[k] !== txt) {
        counted[k] = txt;
        if (!reduced()) { el.classList.remove('hv-count-updated'); void el.offsetWidth; el.classList.add('hv-count-updated'); }
      }
    };
    new MutationObserver(function () {
      // Valeur écrite par l'application pendant le comptage : elle gagne
      // immédiatement (le comptage s'arrête, rien n'est écrasé).
      if (el.__hvCounting && el.textContent !== el.__hvWritten) el.__hvCounting = false;
      if (!el.__hvCounting) { check(); markZero(el); }
    }).observe(el, { childList: true, characterData: true, subtree: true });
    if (countIO) countIO.observe(el); else { el.__hvVis = true; check(); }
    el.__hvCheck = check;
  }
  var countIO = typeof IntersectionObserver === 'function' ? new IntersectionObserver(function (es) {
    es.forEach(function (e) { e.target.__hvVis = e.isIntersecting; if (e.isIntersecting && e.target.__hvCheck) e.target.__hvCheck(); });
  }, { threshold: 0.6 }) : null;
  function scanCounts() { Array.prototype.forEach.call(document.querySelectorAll(COUNT_SEL), watchCount); }

  // ---------- HAYEVA Signature : animation de confirmation de rendez-vous ----------
  // Appelée par le tunnel de réservation (index.html) : start() au clic sur
  // « Confirmer », success(statut) UNIQUEMENT après la réponse positive du
  // serveur, fail() en cas d'échec. Purement visuelle : aucune donnée, aucune
  // décision de réservation ne passe par ici. Logo : fichier officiel PNG
  // transparent (images/brand), jamais redessiné ni recoloré.
  var seal = null, sealT0 = 0, sealTimers = [], sealDone = false;
  var SEAL_MIN = 900;    // le cercle, le logo et la couronne ont le temps d'apparaître
  var SEAL_HOLD = 650;   // coche + texte visibles avant la sortie (total ≈ 1,6 à 1,9 s)
  function sealReduced() { return !!(mq && mq.matches); }
  function sealLater(fn, ms) { sealTimers.push(setTimeout(fn, ms)); }
  function sealClear() { sealTimers.forEach(clearTimeout); sealTimers = []; }
  function sealBuild() {
    var el = document.createElement('div');
    el.className = 'hv-seal';
    el.setAttribute('role', 'status');
    el.setAttribute('aria-live', 'polite');
    el.innerHTML =
      '<div class="hv-seal-medal">' +
        '<svg class="hv-seal-svg" viewBox="0 0 200 200" aria-hidden="true" focusable="false">' +
          '<defs><linearGradient id="hvSealCrownGrad" x1="0" y1="0" x2="1" y2="0">' +
            '<stop offset="0" stop-color="#E3B47F" stop-opacity="0"/><stop offset=".55" stop-color="#F6DDBA"/><stop offset="1" stop-color="#FFFFFF"/>' +
          '</linearGradient></defs>' +
          '<circle class="hv-seal-track" cx="100" cy="100" r="92"/>' +
          '<circle class="hv-seal-ring" cx="100" cy="100" r="92" pathLength="100"/>' +
          '<g class="hv-seal-crown-g"><circle class="hv-seal-crown" cx="100" cy="100" r="92" pathLength="100"/></g>' +
        '</svg>' +
        '<img class="hv-seal-logo" src="images/brand/hayeva-logo-sm.png" ' +
          'srcset="images/brand/hayeva-logo-sm.png 500w, images/brand/hayeva-logo.png 900w" sizes="150px" ' +
          'width="900" height="607" alt="HAYEVA" decoding="async">' +
        '<span class="hv-seal-check" aria-hidden="true"><svg viewBox="0 0 24 24" focusable="false"><path d="M6 12.5l4 4 8-9" pathLength="1"/></svg></span>' +
      '</div>' +
      '<p class="hv-seal-title">Envoi de votre demande…</p>' +
      '<p class="hv-seal-sub"></p>';
    return el;
  }
  function sealRemove(fast) {
    if (!seal) return;
    var el = seal; seal = null; sealClear();
    el.classList.add('is-out');
    setTimeout(function () { if (el.parentNode) el.parentNode.removeChild(el); }, (fast || sealReduced()) ? 0 : 340);
  }
  function sealStart(btn) {
    if (seal) return;
    sealDone = false;
    if (btn && !sealReduced()) { btn.classList.remove('hv-seal-press'); void btn.offsetWidth; btn.classList.add('hv-seal-press'); setTimeout(function () { btn.classList.remove('hv-seal-press'); }, 520); }
    seal = sealBuild();
    if (sealReduced()) seal.classList.add('is-static');
    document.body.appendChild(seal);
    sealT0 = Date.now();
    void seal.offsetWidth;
    seal.classList.add('is-in');
    // Garde-fou : si le tunnel ne rappelle jamais (exception inattendue), le
    // voile ne bloque pas l'écran ; le message d'erreur existant reste affiché.
    sealLater(function () { if (!sealDone) sealRemove(); }, 20000);
    // Vérification anti-robot (Turnstile) qui demande une action : le voile
    // s'efface aussitôt pour ne jamais la masquer.
    var watch = function () {
      if (!seal || sealDone) return;
      var ts = document.querySelectorAll('.hv-turnstile');
      for (var i = 0; i < ts.length; i++) if (ts[i].offsetHeight > 20) { sealRemove(true); return; }
      sealLater(watch, 250);
    };
    sealLater(watch, 250);
  }
  function sealSuccess(status) {
    if (!seal) return;
    sealDone = true;
    var el = seal;
    var wait = sealReduced() ? 0 : Math.max(0, SEAL_MIN - (Date.now() - sealT0));
    sealLater(function () {
      // Statut réel renvoyé par le serveur : « Rendez-vous confirmé » seulement
      // s'il l'indique explicitement, sinon « Demande envoyée ».
      var confirmed = String(status || '').toUpperCase() === 'CONFIRMED';
      el.querySelector('.hv-seal-title').textContent = confirmed ? 'Rendez-vous confirmé' : 'Demande envoyée';
      el.querySelector('.hv-seal-sub').textContent = confirmed ? 'Votre créneau est réservé.' : 'Nous vous confirmons rapidement votre créneau.';
      el.classList.add('is-ok');
      sealLater(function () { sealRemove(); }, sealReduced() ? 1100 : SEAL_HOLD);
    }, wait);
  }
  function sealFail() { sealDone = true; sealRemove(true); }
  window.hvSeal = { start: sealStart, success: sealSuccess, fail: sealFail };

  function boot() {
    bootPanels(); bootPublic(); scanInd(); bootPlanning(); bootScroll(); scanCounts();
    if (typeof MutationObserver === 'function') {
      var tc = 0;
      new MutationObserver(function () { clearTimeout(tc); tc = setTimeout(scanCounts, 80); })
        .observe(document.body, { childList: true, subtree: true });
    }
    if (typeof MutationObserver === 'function') {
      var t = 0;
      new MutationObserver(function () { clearTimeout(t); t = setTimeout(scanInd, 60); })
        .observe(document.body, { childList: true, subtree: true, attributes: true, attributeFilter: ['hidden'] });
    }
  }
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', boot); else boot();
})();
