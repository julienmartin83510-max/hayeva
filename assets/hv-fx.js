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

  window.HvFx = { reduced: reduced, reveal: reveal, count: count, success: success, error: error };
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

  function boot() { bootPanels(); bootPublic(); }
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', boot); else boot();
})();
