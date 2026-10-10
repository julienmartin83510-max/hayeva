// =====================================================================
// HAYEVA — page /parrainage/ (présentation du programme et inscription).
//
// - Le barème affiché vient UNIQUEMENT de get_referral_public_config()
//   (aucun montant écrit en dur) ; sans réponse du serveur, des formulations
//   neutres remplacent les montants.
// - L'inscription n'est proposée que si le programme est publié et que les
//   demandes des particuliers sont ouvertes (activations de l'administration).
// - La demande passe par submit_referrer_application() : vérification
//   anti-robot (Turnstile, laissez-passer à usage unique dans l'en-tête
//   x-hayeva-captcha, revérifié côté SQL). La confirmation n'est affichée
//   qu'après une réponse { ok: true } du serveur.
// - Clé publique (publishable) uniquement : aucune clé secrète ici.
// =====================================================================
(function(){
  'use strict';
  var SB_URL = 'https://hvlzdsuyhrhaflwutwml.supabase.co';
  var SB_KEY = 'sb_publishable_doi6KhNWHhfZ6oT13FLTIg_lPwXbt4a';
  var FN_BASE = SB_URL + '/functions/v1/';
  var reduced = window.matchMedia && matchMedia('(prefers-reduced-motion: reduce)').matches;

  function rpc(name, args, headers){
    var h = { 'Content-Type': 'application/json', 'apikey': SB_KEY, 'Authorization': 'Bearer ' + SB_KEY };
    if (headers) for (var k in headers) h[k] = headers[k];
    return fetch(SB_URL + '/rest/v1/rpc/' + name, { method: 'POST', headers: h, body: JSON.stringify(args || {}) })
      .then(function(r){ return r.json().catch(function(){ return null; }).then(function(d){ return { ok: r.ok, data: d }; }); });
  }

  // ---------- Révélations, parcours, cartes, accordéons ----------
  var io = 'IntersectionObserver' in window ? new IntersectionObserver(function(es){ es.forEach(function(e){ if (e.isIntersecting){ e.target.classList.add('in'); io.unobserve(e.target); } }); }, { rootMargin: '0px 0px -4% 0px' }) : null;
  document.querySelectorAll('.rv, main > section').forEach(function(el){ if (io && !reduced) io.observe(el); else el.classList.add('in'); });
  var steps = document.getElementById('steps'), items = steps.querySelectorAll('.step');
  function prog(){
    var r = steps.getBoundingClientRect(), vh = innerHeight, p = Math.min(1, Math.max(0, (vh * .62 - r.top) / r.height));
    steps.style.setProperty('--p', reduced ? 1 : p.toFixed(3));
    items.forEach(function(it){ var ir = it.getBoundingClientRect(); it.classList.toggle('on', reduced || ir.top < vh * .66); });
  }
  var tk = false;
  addEventListener('scroll', function(){ if (!tk){ tk = true; requestAnimationFrame(function(){ tk = false; prog(); }); } }, { passive: true });
  prog();
  document.querySelectorAll('.svc-head').forEach(function(b){ b.addEventListener('click', function(){ var c = b.parentNode, o = !c.classList.contains('open'); c.classList.toggle('open', o); b.setAttribute('aria-expanded', o); }); });
  document.querySelectorAll('[data-acc]').forEach(function(acc){
    acc.querySelectorAll('.acc-q').forEach(function(q){ q.addEventListener('click', function(){
      var it = q.parentNode, o = !it.classList.contains('open');
      acc.querySelectorAll('.acc-i.open').forEach(function(x){ if (x !== it){ x.classList.remove('open'); x.querySelector('.acc-q').setAttribute('aria-expanded', 'false'); } });
      it.classList.toggle('open', o); q.setAttribute('aria-expanded', o);
    }); });
  });

  // ---------- Barème (serveur uniquement) ----------
  function euros(c){
    var v = Number(c) / 100;
    return v.toLocaleString('fr-FR', { minimumFractionDigits: (Number(c) % 100) ? 2 : 0, maximumFractionDigits: 2 }) + ' €';
  }
  function cents(cfg, key){
    if (!cfg) return null;
    var n = { reward: cfg.reward_cents, advantage: cfg.referee_advantage_cents, min: cfg.min_eligible_paid_cents }[key];
    // Récompense variable selon la prestation : aucun montant unique affiché.
    if (key === 'reward' && cfg.reward_rules_uniform === false) return null;
    return (typeof n === 'number' && n > 0) ? n : null;
  }
  function fillAmounts(cfg){
    document.querySelectorAll('[data-cfg]').forEach(function(el){
      var c = cents(cfg, el.getAttribute('data-cfg'));
      el.textContent = c !== null ? (el.getAttribute('data-fmt') || '{v}').replace('{v}', euros(c)) : (el.getAttribute('data-fb') || '');
    });
    document.querySelectorAll('[data-need]').forEach(function(el){
      el.hidden = el.getAttribute('data-need').split(' ').some(function(k){ return cents(cfg, k) === null; });
    });
    document.querySelectorAll('[data-need-fb]').forEach(function(el){
      el.hidden = !el.getAttribute('data-need-fb').split(' ').some(function(k){ return cents(cfg, k) === null; });
    });
  }

  // ---------- État du programme ----------
  function setOpen(open, cfg){
    document.querySelectorAll('[data-join]').forEach(function(b){ b.hidden = !open; });
    document.querySelectorAll('[data-closed]').forEach(function(n){ n.hidden = open; });
    document.documentElement.setAttribute('data-program', open ? 'open' : (cfg && cfg.program_enabled ? 'closed' : 'unavailable'));
  }
  setOpen(false, null);
  rpc('get_referral_public_config').then(function(r){ return r.ok ? r.data : null; }, function(){ return null; }).then(function(cfg){
    var c = (cfg && cfg.program_enabled) ? cfg : null;
    fillAmounts(c);
    setOpen(!!(c && c.ambassador_public_enabled && c.individual_applications_public_enabled), cfg);
  });

  // ---------- Vérification anti-robot (même mécanisme que le site) ----------
  var keyPromise = null, scriptPromise = null;
  function siteKey(){
    if (!keyPromise){
      keyPromise = fetch(FN_BASE + 'get-public-config').then(function(r){ return r.json(); })
        .then(function(d){ return (d && d.turnstileSiteKey) || null; })
        .catch(function(){ keyPromise = null; return null; });
    }
    return keyPromise;
  }
  function loadScript(){
    if (window.turnstile) return Promise.resolve(window.turnstile);
    if (!scriptPromise){
      scriptPromise = new Promise(function(resolve, reject){
        var s = document.createElement('script');
        s.src = 'https://challenges.cloudflare.com/turnstile/v0/api.js?render=explicit';
        s.async = true;
        s.onload = function(){ window.turnstile ? resolve(window.turnstile) : reject(new Error('turnstile_unavailable')); };
        s.onerror = function(){ scriptPromise = null; reject(new Error('turnstile_unavailable')); };
        document.head.appendChild(s);
      });
    }
    return scriptPromise;
  }
  function captchaError(code){
    var e = new Error(code === 'rate_limited' ? 'Trop de tentatives. Merci de patienter quelques minutes avant de réessayer.'
      : code === 'expired' ? 'La vérification de sécurité a expiré. Merci de réessayer.'
      : 'La vérification anti-robot n\'a pas abouti. Merci de réessayer.');
    e.hvCaptcha = true;
    return e;
  }
  function token(btn){
    return siteKey().then(function(key){
      if (!key) return null;
      var label = btn.textContent;
      btn.disabled = true; btn.textContent = 'Vérification de sécurité…';
      var box = document.createElement('div');
      box.className = 'ts-box';
      btn.parentNode.insertBefore(box, btn.nextSibling);
      var widgetId = null;
      function cleanup(){
        try { if (widgetId !== null && window.turnstile) window.turnstile.remove(widgetId); } catch(e){}
        if (box.parentNode) box.parentNode.removeChild(box);
        btn.textContent = label;
      }
      return loadScript().then(function(ts){
        return new Promise(function(resolve, reject){
          var done = false;
          function finish(fn, v){ if (done) return; done = true; clearTimeout(timer); cleanup(); fn(v); }
          var timer = setTimeout(function(){ finish(reject, captchaError('expired')); }, 180000);
          widgetId = ts.render(box, {
            sitekey: key, size: (box.getBoundingClientRect().width || 0) < 300 ? 'compact' : 'flexible',
            appearance: 'interaction-only', theme: 'light', language: 'fr',
            callback: function(t){ finish(resolve, t); },
            'error-callback': function(){ finish(reject, captchaError('error')); return true; },
            'expired-callback': function(){ finish(reject, captchaError('expired')); },
            'timeout-callback': function(){ finish(reject, captchaError('expired')); }
          });
        });
      }, function(){ cleanup(); throw captchaError('error'); });
    });
  }
  function pass(purpose, btn){
    return token(btn).then(function(t){
      if (!t) return null;
      btn.disabled = true;
      return fetch(FN_BASE + 'verify-turnstile', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ token: t, purpose: purpose }) })
        .then(function(r){ return r.json().catch(function(){ return {}; }); }, function(){ return {}; })
        .then(function(d){
          if (d && d.success && d.pass) return d.pass;
          if (d && d.error === 'not_configured') return null;
          throw captchaError(d && d.error === 'rate_limited' ? 'rate_limited' : (d && d.error === 'expired_token' ? 'expired' : 'error'));
        });
    });
  }

  // ---------- Feuille d'inscription ----------
  var sheet = document.getElementById('sheet'), last = null;
  var bg = document.querySelectorAll('body > header, body > main, body > footer');
  function inert(on){ bg.forEach(function(n){ if (on) n.setAttribute('inert', ''); else n.removeAttribute('inert'); }); }
  function openS(){
    last = document.activeElement; inert(true);
    sheet.classList.remove('done'); sheet.classList.add('open'); sheet.setAttribute('aria-hidden', 'false');
    setTimeout(function(){ var f = sheet.querySelector('input'); if (f) f.focus(); }, 80);
  }
  function closeS(){ inert(false); sheet.classList.remove('open'); sheet.setAttribute('aria-hidden', 'true'); if (last && last.focus) last.focus(); }
  document.querySelectorAll('[data-join]').forEach(function(b){ b.addEventListener('click', openS); });
  document.getElementById('sheetX').addEventListener('click', closeS);
  sheet.addEventListener('click', function(e){ if (e.target === sheet) closeS(); });
  addEventListener('keydown', function(e){ if (e.key === 'Escape' && sheet.classList.contains('open')) closeS(); });
  // Lien « règlement » de la case à cocher : ferme la feuille et ouvre les conditions.
  sheet.querySelectorAll('a[href="#conditions"]').forEach(function(a){ a.addEventListener('click', function(){ closeS(); }); });

  var ERR = {
    VERIFICATION: 'La vérification anti-robot n\'a pas abouti. Merci de réessayer.',
    NOM: 'Merci d\'indiquer votre prénom et votre nom.',
    EMAIL: 'Merci d\'indiquer un e-mail valide.',
    TELEPHONE: 'Merci d\'indiquer un numéro de téléphone valide.',
    CONDITIONS: 'Merci d\'accepter le règlement du programme.',
    TROP_DE_DEMANDES: 'Trop de demandes en ce moment : réessayez un peu plus tard.',
    INDISPONIBLE: 'Les demandes ne sont pas ouvertes pour le moment.'
  };
  var form = document.getElementById('joinForm'), msg = document.getElementById('joinMsg'), btn = document.getElementById('joinSubmit');
  function show(t){ msg.textContent = t || ''; msg.hidden = !t; }
  function val(id){ return (document.getElementById(id).value || '').trim(); }
  var busy = false;
  form.addEventListener('submit', function(e){
    e.preventDefault();
    if (busy) return;
    if (!val('jFirst') || !val('jLast')) return show(ERR.NOM);
    if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(val('jEmail'))) return show(ERR.EMAIL);
    if (val('jPhone').replace(/\D/g, '').length < 9) return show(ERR.TELEPHONE);
    if (!document.getElementById('jTerms').checked) return show(ERR.CONDITIONS);
    busy = true; btn.disabled = true; show('');
    pass('referrer_application', btn).then(function(captcha){
      return rpc('submit_referrer_application', {
        p_first_name: val('jFirst'), p_last_name: val('jLast'), p_email: val('jEmail'), p_phone: val('jPhone'),
        p_terms_accepted: document.getElementById('jTerms').checked
      }, captcha ? { 'x-hayeva-captcha': captcha } : null);
    }).then(function(r){
      busy = false; btn.disabled = false;
      var out = (r && r.data) || {};
      if (!r.ok || !out.ok){ show(ERR[out.error] || 'Envoi impossible pour le moment. Réessayez dans un instant.'); return; }
      form.reset();
      sheet.classList.add('done');
      var h = sheet.querySelector('.ok h3'); if (h){ h.setAttribute('tabindex', '-1'); h.focus(); }
    }, function(err){
      busy = false; btn.disabled = false;
      show(err && err.hvCaptcha ? err.message : 'Connexion impossible. Vérifiez votre réseau et réessayez.');
    });
  });
  // Préchargement discret de la clé de site (aucun script Cloudflare avant l'envoi).
  siteKey();
})();
