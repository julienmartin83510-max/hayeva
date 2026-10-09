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

  function boot() {
    bootPanels(); bootPublic(); scanInd(); bootPlanning();
    if (typeof MutationObserver === 'function') {
      var t = 0;
      new MutationObserver(function () { clearTimeout(t); t = setTimeout(scanInd, 60); })
        .observe(document.body, { childList: true, subtree: true, attributes: true, attributeFilter: ['hidden'] });
    }
  }
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', boot); else boot();
})();
