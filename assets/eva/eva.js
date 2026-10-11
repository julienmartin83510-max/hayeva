// =====================================================================
// EVA — assistante de gestion HAYEVA (V1, sans IA payante).
// - Comprend une commande en français grâce à EVAIntents (règles locales,
//   aucune donnée envoyée à un service d'IA).
// - Interroge le serveur via eva_run (rôle administrateur revérifié,
//   données RÉELLES du planning, des devis et des factures).
// - Toute écriture passe par une proposition (eva_propose) que vous
//   confirmez par un bouton : jamais par une phrase.
// - Micro : dictée du navigateur (Apple sur iPhone), uniquement quand
//   vous touchez le bouton. Aucune écoute en arrière-plan.
// =====================================================================
(function(){
  'use strict';
  if (window.EVA) return;
  var I = window.EVAIntents;
  var sb = function(){ return window.sudSupabase && window.sudSupabase.client; };
  var root, feed, input, micBtn, hintEl, state = { tab: 'today', overview: null, reg: {}, seq: 0, voice: false, listening: false };
  var TTS_KEY = 'hv_eva_tts';

  // ---------------------------------------------------------------- outils
  function esc(s){ return String(s == null ? '' : s).replace(/[&<>"']/g, function(c){ return { '&':'&amp;', '<':'&lt;', '>':'&gt;', '"':'&quot;', "'":'&#39;' }[c]; }); }
  function eur(c){ if (c == null) return '—'; var v = Number(c) / 100; return v.toLocaleString('fr-FR', { minimumFractionDigits: Number(c) % 100 ? 2 : 0, maximumFractionDigits: 2 }) + ' €'; }
  function parseIso(d){ var m = /^(\d{4})-(\d{2})-(\d{2})/.exec(String(d || '')); return m ? new Date(+m[1], +m[2] - 1, +m[3]) : null; }
  function dayLabel(d){ var x = parseIso(d); if (!x) return ''; var s = x.toLocaleDateString('fr-FR', { weekday: 'long', day: 'numeric', month: 'long' }); return s.charAt(0).toUpperCase() + s.slice(1); }
  function relDay(d){
    var x = parseIso(d), t = new Date(); t.setHours(0, 0, 0, 0); if (!x) return '';
    var diff = Math.round((x - t) / 86400000);
    return diff === 0 ? "Aujourd'hui" : diff === 1 ? 'Demain' : diff === -1 ? 'Hier' : dayLabel(d);
  }
  function key(){ return 'ui-' + Date.now().toString(36) + '-' + Math.random().toString(36).slice(2, 10); }
  function reg(o){ var k = 'r' + (++state.seq); state.reg[k] = o; return k; }
  var STATUS = { PENDING: ['À confirmer', 'wait'], CONFIRMED: ['Confirmé', 'ok'], IN_PROGRESS: ['En cours', 'info'], COMPLETED: ['Terminé', 'ok'] };
  var AGENT = { planning: 'Agent Planning', devis: 'Agent Devis', factures: 'Agent Factures' };
  var ERR = {
    EVA_DESACTIVEE: 'EVA est désactivée dans les réglages.',
    TROP_DE_DEMANDES: 'Trop de demandes en une minute : patientez un instant.',
    LIMITE_JOURNALIERE: 'Limite quotidienne de commandes atteinte.',
    DATE_INVALIDE: 'Date non reconnue.',
    PERIODE_INVALIDE: 'Période trop longue : limitez-la à un mois.',
    INTENTION_INCONNUE: 'Commande non prise en charge.',
    DOSSIER_OCCUPE: 'Une proposition est déjà en attente sur ce dossier : confirmez-la ou annulez-la d’abord (onglet Propositions).',
    CONFIRMATION_REQUISE: 'Confirmation explicite requise.'
  };
  function errText(e){
    var m = String((e && (e.message || e.details)) || e || '');
    if (/PGRST202|Could not find the function|does not exist/i.test(m)) return 'EVA n’est pas encore installée sur la base de données (migration 0135 à appliquer).';
    var a = /AGENT_DESACTIVE:(\w+)/.exec(m); if (a) return (AGENT[a[1]] || 'Cet agent') + ' est désactivé dans les réglages.';
    for (var k in ERR) if (m.indexOf(k) !== -1) return ERR[k];
    if (/réservée|42501|permission/i.test(m)) return 'Action réservée à l’administrateur connecté.';
    if (/JWT|session/i.test(m)) return 'Votre session a expiré : reconnectez-vous.';
    return m && m.length < 220 ? m : 'EVA n’a pas pu répondre. Réessayez dans un instant.';
  }
  function rpc(name, args){
    var c = sb(); if (!c) return Promise.reject(new Error('Service indisponible.'));
    return c.rpc(name, args || {}).then(function(r){ if (r.error) throw r.error; return r.data; });
  }
  function speak(text){
    if (!state.voice || !window.speechSynthesis) return;
    try { if (localStorage.getItem(TTS_KEY) === '0') return; } catch (e){}
    try { var u = new SpeechSynthesisUtterance(text); u.lang = 'fr-FR'; window.speechSynthesis.cancel(); window.speechSynthesis.speak(u); } catch (e){}
  }

  // ------------------------------------------------------------- structure
  var ICON = {
    close: '<svg viewBox="0 0 24 24"><path d="M18 6 6 18M6 6l12 12"/></svg>',
    mic: '<svg viewBox="0 0 24 24"><rect x="9" y="3" width="6" height="11" rx="3"/><path d="M5 11a7 7 0 0 0 14 0M12 18v3"/></svg>',
    send: '<svg viewBox="0 0 24 24"><path d="M5 12h14M13 6l6 6-6 6"/></svg>'
  };
  function build(){
    root = document.createElement('div');
    root.className = 'eva'; root.id = 'evaRoot'; root.hidden = true;
    root.setAttribute('role', 'dialog'); root.setAttribute('aria-modal', 'true'); root.setAttribute('aria-labelledby', 'evaTitle');
    root.innerHTML =
      '<div class="eva-top">' +
        '<img class="eva-logo" src="' + (location.protocol === 'file:' ? '' : '/') + 'images/brand/hayeva-logo-sm.png" alt="HAYEVA" width="900" height="607">' +
        '<div class="eva-id"><h1 id="evaTitle">E<span>V</span>A</h1><p>Votre assistante HAYEVA</p></div>' +
        '<button type="button" class="eva-x" data-act="close" aria-label="Fermer EVA">' + ICON.close + '</button>' +
      '</div>' +
      '<div class="eva-tabs" role="tablist" aria-label="Rubriques EVA">' +
        tabBtn('today', 'Aujourd’hui') + tabBtn('proposals', 'À valider <span class="eva-badge" id="evaPropBadge" hidden>0</span>') +
        tabBtn('history', 'Historique') + tabBtn('settings', 'Réglages') +
      '</div>' +
      '<div class="eva-body" id="evaBody">' +
        '<section class="eva-pane" data-pane="today" role="tabpanel" aria-label="Aujourd’hui">' +
          '<div class="eva-tiles" id="evaTiles"></div>' +
          '<div class="eva-chips" id="evaChips" aria-label="Commandes rapides"></div>' +
          '<div class="eva-feed" id="evaFeed" aria-live="polite"></div>' +
        '</section>' +
        '<section class="eva-pane" data-pane="proposals" role="tabpanel" aria-label="Propositions à valider" hidden></section>' +
        '<section class="eva-pane" data-pane="history" role="tabpanel" aria-label="Historique" hidden></section>' +
        '<section class="eva-pane" data-pane="settings" role="tabpanel" aria-label="Réglages" hidden></section>' +
      '</div>' +
      '<form class="eva-bar" id="evaForm" autocomplete="off">' +
        '<div class="eva-bar-in">' +
          '<button type="button" class="eva-mic" id="evaMic" aria-pressed="false" aria-label="Dicter une commande">' + ICON.mic + '</button>' +
          '<label class="eva-sr" for="evaInput">Commande pour EVA</label>' +
          '<input class="eva-input" id="evaInput" type="text" enterkeyhint="send" maxlength="300" placeholder="EVA, montre-moi mes interventions de demain">' +
          '<button type="submit" class="eva-send" aria-label="Envoyer">' + ICON.send + '</button>' +
        '</div>' +
        '<p class="eva-hint" id="evaHint"></p>' +
      '</form>';
    document.body.appendChild(root);
    feed = root.querySelector('#evaFeed'); input = root.querySelector('#evaInput'); micBtn = root.querySelector('#evaMic'); hintEl = root.querySelector('#evaHint');
    root.querySelector('#evaChips').innerHTML = I.SUGGESTIONS.map(function(s){ return '<button type="button" class="eva-chip" data-act="run" data-cmd="' + esc(s) + '">' + esc(s) + '</button>'; }).join('');
    root.querySelector('#evaForm').addEventListener('submit', function(e){ e.preventDefault(); var v = input.value.trim(); if (!v) return; input.value = ''; run(v, false); });
    root.addEventListener('click', onClick);
    root.addEventListener('change', onChange);
    root.addEventListener('keydown', function(e){ if (e.key === 'Escape') close(); });
    micBtn.addEventListener('click', toggleMic);
  }
  function tabBtn(k, label){ return '<button type="button" class="eva-tab" role="tab" data-act="tab" data-tab="' + k + '" aria-selected="' + (k === 'today') + '">' + label + '</button>'; }

  var lastFocus = null;
  function open(){
    if (!root) build();
    lastFocus = document.activeElement;
    root.hidden = false;
    document.documentElement.style.overflow = 'hidden';
    requestAnimationFrame(function(){ root.classList.add('is-open'); });
    setTab('today');
    loadToday();
    setTimeout(function(){ try { input.focus({ preventScroll: true }); } catch (e){} }, 120);
  }
  function close(){
    if (!root || root.hidden) return;
    stopMic();
    root.classList.remove('is-open');
    document.documentElement.style.overflow = '';
    root.hidden = true;
    if (lastFocus && lastFocus.focus) try { lastFocus.focus(); } catch (e){}
  }
  function setTab(k){
    state.tab = k;
    root.querySelectorAll('.eva-tab').forEach(function(b){ b.setAttribute('aria-selected', b.getAttribute('data-tab') === k ? 'true' : 'false'); });
    root.querySelectorAll('.eva-pane').forEach(function(p){ p.hidden = p.getAttribute('data-pane') !== k; });
    root.querySelector('#evaForm').hidden = k === 'settings';
    if (k !== 'today') loadOverview();
  }

  // ------------------------------------------------------ « Aujourd'hui »
  function tile(n, label, cmd, alert){ return '<button type="button" class="eva-tile' + (alert ? ' is-alert' : '') + '" data-act="run" data-cmd="' + esc(cmd) + '"><b>' + n + '</b><span>' + esc(label) + '</span></button>'; }
  function loadToday(){
    var t = root.querySelector('#evaTiles');
    t.innerHTML = ['Interventions du jour', 'Devis à valider', 'Factures à préparer', 'Anomalies'].map(function(l){ return '<div class="eva-tile is-loading"><b>…</b><span>' + l + '</span></div>'; }).join('');
    rpc('eva_run', { p_intent: 'brief', p_args: { date: I.iso(new Date()) }, p_command: null }).then(function(r){
      var d = r.data || {}, ag = d.agenda, q = d.quotes, inv = d.invoices, att = (d.attention && d.attention.items) || [];
      var nInt = ag ? ag.interventions.length : '–';
      var nQ = q ? q.drafts.length : '–';
      var nF = inv ? inv.completed_without_invoice.length + inv.accepted_quotes_without_invoice.length : '–';
      var nA = att.filter(function(x){ return x.level !== 'action'; }).length;
      t.innerHTML = tile(nInt, 'Interventions du jour', "Montre-moi mes interventions d'aujourd'hui") + tile(nQ, 'Devis à valider', 'Prépare mes devis en attente') +
        tile(nF, 'Factures à préparer', 'Prépare les factures des interventions terminées') + tile(nA, 'Anomalies', 'Quels dossiers nécessitent mon attention ?', nA > 0);
      updateBadge();
    }, function(e){ t.innerHTML = ''; addCard(errorCard(errText(e))); });
  }

  // ----------------------------------------------------------- exécution
  function run(text, byVoice){
    state.voice = !!byVoice;
    if (state.tab !== 'today') setTab('today');
    var plan = I.parse(text);
    var seq = Promise.resolve();
    plan.forEach(function(p){
      seq = seq.then(function(){ return runOne(p, text); });
    });
    return seq;
  }
  function runOne(p, fullText){
    if (p.intent === 'empty') return;
    if (p.intent === 'unknown'){
      addCard('<div class="eva-card"><div class="eva-card-head"><span class="eva-agent">EVA</span><span class="eva-q">« ' + esc(p.text) + ' »</span></div>' +
        '<p class="eva-sum">Je n’ai pas compris cette demande.</p><p class="eva-note">Je ne réponds qu’à partir de vos données réelles. Essayez par exemple :</p>' +
        '<div class="eva-actions">' + I.SUGGESTIONS.slice(0, 4).map(function(s){ return '<button type="button" class="eva-btn sm ghost" data-act="run" data-cmd="' + esc(s) + '">' + esc(s) + '</button>'; }).join('') + '</div></div>');
      speak('Je n’ai pas compris cette demande.');
      return;
    }
    if (p.intent === 'not_yet') return notYet(p);
    if (p.intent === 'dev_request') return devRequestCard(p);
    var holder = addCard('<div class="eva-card"><div class="eva-card-head"><span class="eva-agent">EVA</span><span class="eva-q">« ' + esc(p.text) + ' »</span></div><p class="eva-empty">Je consulte vos données…</p></div>');
    if (p.intent === 'invoice_last') return invoiceLast(p, holder);
    if (p.intent === 'move_booking') return moveBooking(p, holder);
    return rpc('eva_run', { p_intent: p.intent, p_args: p.args, p_command: p.text }).then(function(r){
      var out = render(p, r);
      holder.outerHTML = out.html;
      speak(out.say);
    }, function(e){ holder.outerHTML = errorCard(errText(e), p.text); speak(errText(e)); });
  }
  function addCard(html){
    var w = document.createElement('div'); w.innerHTML = html;
    var el = w.firstElementChild; feed.insertBefore(el, feed.firstChild);
    var body = root.querySelector('#evaBody'); if (body) body.scrollTop = 0;
    return el;
  }
  function errorCard(msg, q){ return '<div class="eva-card eva-err"><div class="eva-card-head"><span class="eva-agent">EVA</span>' + (q ? '<span class="eva-q">« ' + esc(q) + ' »</span>' : '') + '</div><p class="eva-sum">' + esc(msg) + '</p></div>'; }
  function card(agent, q, sum, body){
    return '<div class="eva-card"><div class="eva-card-head"><span class="eva-agent">' + esc(AGENT[agent] || 'EVA') + '</span><span class="eva-q">« ' + esc(q) + ' »</span></div>' +
      '<p class="eva-sum">' + esc(sum) + '</p>' + (body || '') + '</div>';
  }

  // -------------------------------------------------------------- rendus
  function render(p, r){
    var d = r.data || {};
    switch (p.intent){
      case 'agenda': return renderAgenda(p, d);
      case 'free_slots': return renderSlots(p, d, null);
      case 'conflicts': return renderConflicts(p, d);
      case 'find_client': return renderClients(p, d);
      case 'quote_estimate': return renderEstimate(p, d);
      case 'quotes_pending': return renderQuotes(p, d);
      case 'invoices_todo': return renderInvoices(p, d);
      case 'attention': return renderAttention(p, d, 'Points d’attention');
      case 'brief': return renderBrief(p, d);
      case 'finance': return renderFinance(p, d);
      case 'client_quotes': return renderClientQuotes(p, d);
      case 'awaiting': return renderAwaiting(p, d);
      case 'capabilities': return renderCapabilities(p, d);
    }
    return { html: errorCard('Réponse inattendue.', p.text), say: '' };
  }

  function agendaItems(d){
    return '<ul class="eva-list">' + d.interventions.map(function(x){
      var st = STATUS[x.status] || [x.status, 'info'];
      var mv = (x.status === 'PENDING' || x.status === 'CONFIRMED') ? '<div class="eva-actions"><button type="button" class="eva-btn sm ghost" data-act="move" data-k="' + reg({ booking_id: x.booking_id, duration: x.duration_minutes, reference: x.reference }) + '">Proposer un autre créneau</button></div>' : '';
      return '<li class="eva-item"><div class="eva-time">' + esc(x.start) + '<small>' + esc(x.end) + '</small></div><div class="eva-main"><b>' + esc(x.service) + '</b>' +
        '<span>' + esc(x.client) + ' · ' + esc(x.reference) + '</span>' + (x.address ? '<span>' + esc(x.address) + '</span>' : '') +
        (x.phone ? '<a href="tel:' + esc(String(x.phone).replace(/\s/g, '')) + '">' + esc(x.phone) + '</a>' : '') +
        (x.within_hours === false ? '<span style="color:#F7CF84">En dehors de vos horaires de travail</span>' : '') + mv + '</div>' +
        '<span class="eva-pill ' + st[1] + '">' + esc(st[0]) + '</span></li>';
    }).join('') + '</ul>';
  }
  function agendaExtras(d){
    var h = '';
    if (d.busy_blocks && d.busy_blocks.length) h += '<p class="eva-h">Indisponibilités (calendrier Apple)</p><ul class="eva-list">' + d.busy_blocks.map(function(b){
      return '<li class="eva-item"><div class="eva-time">' + (b.all_day ? 'Journée' : esc(b.start) + '<small>' + esc(b.end) + '</small>') + '</div><div class="eva-main"><b>Occupé</b><span>' + esc(b.source || 'Calendrier') + '</span></div></li>';
    }).join('') + '</ul>';
    if (d.warnings && d.warnings.length) h += '<div class="eva-warn">' + d.warnings.map(function(w){ return '<p>' + esc(w.message) + '</p>'; }).join('') + '</div>';
    return h;
  }
  function renderAgenda(p, d){
    var n = d.interventions.length, day = relDay(d.date), full = dayLabel(d.date);
    if (!n){
      var closed = !d.work_ranges || !d.work_ranges.length;
      var s = day + ' (' + full + ') : aucune intervention dans votre planning.';
      return { html: card('planning', p.text, s, (closed ? '<p class="eva-note">Jour non travaillé selon vos horaires.</p>' : '<p class="eva-note">Horaires : ' + esc(d.work_ranges.join(' et ')) + '.</p>') + agendaExtras(d)), say: s };
    }
    var first = d.interventions[0];
    var sum = day + ' : ' + n + ' intervention' + (n > 1 ? 's' : '') + ', la première à ' + first.start + ' (' + first.client + ').';
    return { html: card('planning', p.text, sum, '<p class="eva-note" style="margin:-6px 0 10px">' + esc(full) + '</p>' + agendaItems(d) + agendaExtras(d)), say: sum };
  }
  function renderSlots(p, d, ctx){
    var by = {};
    d.slots.forEach(function(s){ (by[s.date] = by[s.date] || []).push(s); });
    var days = Object.keys(by);
    var sum = days.length ? d.slots.length + ' créneau' + (d.slots.length > 1 ? 'x' : '') + ' libre' + (d.slots.length > 1 ? 's' : '') + ' de ' + d.duration_minutes + ' min (marge de trajet ' + d.travel_margin_minutes + ' min incluse).'
      : 'Aucun créneau libre de ' + d.duration_minutes + ' min sur cette période.';
    var body = days.map(function(k){
      return '<p class="eva-h">' + esc(dayLabel(k)) + '</p><div class="eva-actions" style="margin-top:0">' + by[k].map(function(s){
        return ctx ? '<button type="button" class="eva-btn sm ghost" data-act="pick" data-k="' + reg({ booking_id: ctx.booking_id, date: s.date, start: s.start, idem: key() }) + '">' + esc(s.start) + '</button>'
                   : '<span class="eva-pill info" style="font-size:.82rem">' + esc(s.start) + '–' + esc(s.end) + '</span>';
      }).join('') + '</div>';
    }).join('');
    if (ctx) body = '<p class="eva-note" style="margin-top:-4px">Choisissez un créneau pour ' + esc(ctx.reference) + ' : une proposition vous sera soumise, rien n’est déplacé sans votre confirmation.</p>' + body;
    return { html: card('planning', p.text, sum, body), say: sum };
  }
  function renderConflicts(p, d){
    var c = d.conflicts || [];
    var sum = c.length ? c.length + ' point' + (c.length > 1 ? 's' : '') + ' à vérifier dans votre planning.' : 'Aucun conflit de planning sur la période.';
    var body = c.length ? '<ul class="eva-list">' + c.map(function(x){ return '<li class="eva-item"><div class="eva-time">' + esc((parseIso(x.date) || new Date()).toLocaleDateString('fr-FR', { day: '2-digit', month: '2-digit' })) + '</div><div class="eva-main"><b>' + esc({ chevauchement: 'Chevauchement', trajet: 'Trajet trop court', horaires: 'Hors horaires', calendrier: 'Calendrier Apple' }[x.type] || 'Conflit') + '</b><span>' + esc(x.message) + '</span></div></li>'; }).join('') + '</ul>' : '';
    return { html: card('planning', p.text, sum, body), say: sum };
  }
  function renderClients(p, d){
    var c = d.clients || [];
    var sum = c.length ? c.length + ' client' + (c.length > 1 ? 's' : '') + ' trouvé' + (c.length > 1 ? 's' : '') + '.' : 'Aucun client ne correspond à « ' + (d.query || '') + ' » dans votre base.';
    var body = c.length ? '<ul class="eva-list">' + c.map(function(x){
      return '<li class="eva-item"><div class="eva-main"><b>' + esc(x.name || 'Sans nom') + '</b>' + (x.city ? '<span>' + esc(x.city) + '</span>' : '') +
        (x.phone ? '<a href="tel:' + esc(String(x.phone).replace(/\s/g, '')) + '">' + esc(x.phone) + '</a>' : '') + (x.email ? '<a href="mailto:' + esc(x.email) + '">' + esc(x.email) + '</a>' : '') + '</div></li>';
    }).join('') + '</ul>' : '';
    return { html: card(null, p.text, sum, body), say: sum };
  }
  function renderEstimate(p, d){
    var clients = d.clients || [], matches = d.matches || [], miss = d.missing || [];
    var client = clients.length === 1 ? clients[0] : null;
    var sum = matches.length ? 'Proposition de chiffrage à partir de votre catalogue.' : 'Prestation non trouvée dans votre catalogue : à chiffrer par vous.';
    var body = '';
    if (p.args.client && !clients.length) body += '<div class="eva-warn"><p>Client « ' + esc(p.args.client) + ' » introuvable dans votre base. Vérifiez le nom ou créez la fiche client.</p></div>';
    if (clients.length > 1) body += clientChoice(p, clients, 'quote_estimate', { service: p.args.service });
    if (client) body += '<p class="eva-h">Client</p><p class="eva-note" style="margin:0">' + esc(client.name) + (client.city ? ' · ' + esc(client.city) : '') + '</p>';
    if (matches.length){
      var g = 'est' + (++state.seq);
      body += '<p class="eva-h">Prestations du catalogue</p><div class="eva-list">' + matches.map(function(m, i){
        var priced = m.price_cents != null;
        return '<label class="eva-radio' + (priced ? '' : ' is-off') + '"><input type="radio" name="' + g + '" value="' + i + '"' + (priced && i === 0 ? ' checked' : '') + (priced ? '' : ' disabled') + '>' +
          '<span>' + esc(m.label) + '</span><em>' + (priced ? eur(m.price_cents) : (m.mode === 'FROM' ? 'À partir de… : à chiffrer' : 'Sur devis : à chiffrer')) + '</em></label>';
      }).join('') + '</div>';
      var hasPriced = matches.some(function(m){ return m.price_cents != null; });
      body += '<p class="eva-h">Déplacement</p>' + (d.travel_fee_cents != null
        ? '<p class="eva-note" style="margin:0">' + esc(d.distance_km) + ' km depuis Fréjus : ' + eur(d.travel_fee_cents) + ' (règle de déplacement enregistrée).</p>'
        : '<label class="eva-field">Distance aller (km), si vous la connaissez<input type="number" inputmode="decimal" min="0" max="300" step="0.1" data-role="km" placeholder="Laisser vide si inconnue"></label>');
      if (miss.length) body += '<div class="eva-warn">' + miss.map(function(m){ return '<p>' + esc(m) + '</p>'; }).join('') + '</div>';
      body += '<p class="eva-note">' + esc(d.supplies_note || '') + '</p>';
      if (client && hasPriced) body += '<div class="eva-actions"><button type="button" class="eva-btn cu" data-act="quote" data-k="' + reg({ client_id: client.client_id, matches: matches, group: g, distance: d.distance_km, idem: key() }) + '">Préparer le brouillon de devis</button></div>';
    } else if (miss.length){
      body += '<div class="eva-warn">' + miss.map(function(m){ return '<p>' + esc(m) + '</p>'; }).join('') + '</div>';
    }
    return { html: card('devis', p.text, sum, body), say: sum };
  }
  function renderQuotes(p, d){
    var n = d.drafts.length + d.sent.length + d.accepted_not_invoiced.length;
    var sum = n ? d.drafts.length + ' brouillon(s), ' + d.sent.length + ' envoyé(s) en attente, ' + d.accepted_not_invoiced.length + ' accepté(s) non facturé(s).' : 'Aucun devis en attente.';
    var b = '';
    if (d.drafts.length) b += '<p class="eva-h">Brouillons à finaliser</p><ul class="eva-list">' + d.drafts.map(function(q){ return '<li class="eva-item"><div class="eva-main"><b>' + esc(q.title || q.reference) + '</b><span>' + esc(q.client) + ' · ' + esc(q.reference) + ' · créé il y a ' + q.age_days + ' j</span></div><span class="eva-pill info">' + eur(q.total_cents) + '</span></li>'; }).join('') + '</ul>';
    if (d.sent.length) b += '<p class="eva-h">Envoyés, sans réponse</p><ul class="eva-list">' + d.sent.map(function(q){ return '<li class="eva-item"><div class="eva-main"><b>' + esc(q.client) + '</b><span>' + esc(q.reference) + ' · envoyé il y a ' + q.sent_days + ' j</span></div><span class="eva-pill ' + (q.sent_days > 14 ? 'wait' : 'info') + '">' + eur(q.total_cents) + '</span></li>'; }).join('') + '</ul>';
    if (d.accepted_not_invoiced.length) b += '<p class="eva-h">Acceptés, à facturer</p><ul class="eva-list">' + d.accepted_not_invoiced.map(function(q){ return '<li class="eva-item"><div class="eva-main"><b>' + esc(q.client) + '</b><span>' + esc(q.reference) + '</span><div class="eva-actions"><button type="button" class="eva-btn sm cu" data-act="invoice" data-k="' + reg({ source: 'quote', id: q.quote_id, idem: key() }) + '">Préparer le brouillon de facture</button></div></div><span class="eva-pill ok">' + eur(q.total_cents) + '</span></li>'; }).join('') + '</ul>';
    if (n) b += '<div class="eva-actions"><button type="button" class="eva-btn sm ghost" data-act="goto" data-page="quotes">Ouvrir la rubrique Devis</button></div>';
    return { html: card('devis', p.text, sum, b), say: sum };
  }
  function vatLine(d){
    var reg = { franchise_base: 'Franchise en base de TVA', assujetti: 'Assujetti à la TVA' + (d.default_vat_rate != null ? ' (' + String(d.default_vat_rate).replace('.', ',') + ' %)' : '') }[d.vat_regime] || 'Régime de TVA non renseigné';
    return '<div class="eva-warn"' + (d.vat_confirmed && d.billing_ready ? ' style="background:rgba(95,199,149,.1);color:#9BE0BD"' : '') + '><p>' + esc(reg) + ' — ' + (d.vat_confirmed ? 'confirmé.' : 'à confirmer dans les réglages d’EVA.') + '</p>' +
      '<p>' + (d.billing_ready ? 'Facturation définitive possible (émission depuis la rubrique Factures).' : 'Facturation définitive impossible pour l’instant : informations légales ou régime de TVA à compléter. EVA ne prépare que des brouillons.') + '</p></div>';
  }
  function renderInvoices(p, d){
    var a = d.completed_without_invoice, q = d.accepted_quotes_without_invoice, dr = d.drafts, u = d.unpaid;
    var n = a.length + q.length;
    var sum = n ? n + ' facture' + (n > 1 ? 's' : '') + ' à préparer.' : 'Aucune facture à préparer.';
    if (u.length) sum += ' ' + u.length + ' facture' + (u.length > 1 ? 's' : '') + ' en attente de règlement.';
    var b = vatLine(d);
    if (a.length) b += '<p class="eva-h">Interventions terminées sans facture</p><ul class="eva-list">' + a.map(function(x){
      return '<li class="eva-item"><div class="eva-main"><b>' + esc(x.service) + '</b><span>' + esc(x.client) + ' · ' + esc(x.reference) + ' · ' + esc((parseIso(x.date) || new Date()).toLocaleDateString('fr-FR')) + '</span>' +
        (x.report ? '' : '<span style="color:#F7CF84">Aucun compte rendu d’intervention enregistré.</span>') +
        '<div class="eva-actions"><button type="button" class="eva-btn sm cu" data-act="invoice" data-k="' + reg({ source: 'booking', id: x.booking_id, idem: key() }) + '">Préparer le brouillon</button></div></div><span class="eva-pill info">' + eur(x.total_cents) + '</span></li>';
    }).join('') + '</ul>';
    if (q.length) b += '<p class="eva-h">Devis acceptés non facturés</p><ul class="eva-list">' + q.map(function(x){
      return '<li class="eva-item"><div class="eva-main"><b>' + esc(x.client) + '</b><span>' + esc(x.reference) + '</span><div class="eva-actions"><button type="button" class="eva-btn sm cu" data-act="invoice" data-k="' + reg({ source: 'quote', id: x.quote_id, idem: key() }) + '">Préparer le brouillon</button></div></div><span class="eva-pill info">' + eur(x.total_cents) + '</span></li>';
    }).join('') + '</ul>';
    if (dr.length) b += '<p class="eva-h">Brouillons de facture</p><ul class="eva-list">' + dr.map(function(x){ return '<li class="eva-item"><div class="eva-main"><b>' + esc(x.client) + '</b><span>' + esc(x.reference) + ' · ' + x.lines + ' ligne(s)</span>' +
      (d.billing_ready ? '<div class="eva-actions"><button type="button" class="eva-btn sm cu" data-act="issue" data-k="' + reg({ invoice_id: x.invoice_id, idem: key() }) + '">Émettre</button></div>' : '') + '</div><span class="eva-pill wait">' + eur(x.total_cents) + '</span></li>'; }).join('') + '</ul>';
    if (u.length) b += '<p class="eva-h">Émises, non réglées (paiements enregistrés uniquement)</p><ul class="eva-list">' + u.map(function(x){ return '<li class="eva-item"><div class="eva-main"><b>' + esc(x.client) + '</b><span>' + esc(x.reference) + ' · réglé ' + eur(x.paid_cents) + ' sur ' + eur(x.total_cents) + (x.due_date ? ' · échéance ' + esc((parseIso(x.due_date) || new Date()).toLocaleDateString('fr-FR')) : '') + '</span>' +
      '<div class="eva-actions"><button type="button" class="eva-btn sm ghost" data-act="pay-form" data-k="' + reg({ invoice_id: x.invoice_id, remaining: x.total_cents - x.paid_cents }) + '">Enregistrer un paiement reçu</button></div></div><span class="eva-pill ' + (x.overdue ? 'no' : 'wait') + '">' + (x.overdue ? 'Échue' : 'À régler') + '</span></li>'; }).join('') + '</ul>';
    b += '<div class="eva-actions"><button type="button" class="eva-btn sm ghost" data-act="goto" data-page="invoices">Ouvrir la rubrique Factures</button></div>';
    return { html: card('factures', p.text, sum, b), say: sum };
  }
  var LVL = { alerte: ['Alerte', 'no'], action: ['À traiter', 'wait'], reglage: ['Réglage', 'info'] };
  function attentionList(items){
    return '<ul class="eva-list">' + items.map(function(x){ var l = LVL[x.level] || ['Info', 'info']; return '<li class="eva-item"><div class="eva-main"><b>' + esc(x.message) + '</b><span>' + esc(AGENT[x.agent] || 'EVA') + '</span></div><span class="eva-pill ' + l[1] + '">' + l[0] + '</span></li>'; }).join('') + '</ul>';
  }
  function renderAttention(p, d, title){
    var it = d.items || [];
    var sum = it.length ? it.length + ' point' + (it.length > 1 ? 's' : '') + ' nécessite' + (it.length > 1 ? 'nt' : '') + ' votre attention.' : 'Rien ne nécessite votre attention pour le moment.';
    return { html: card(null, p.text, sum, it.length ? attentionList(it) : ''), say: sum };
  }
  function renderBrief(p, d){
    var ag = d.agenda, parts = [], b = '';
    if (ag){
      var n = ag.interventions.length;
      parts.push(n ? n + ' intervention' + (n > 1 ? 's' : '') + (n ? ', la première à ' + ag.interventions[0].start : '') : 'aucune intervention');
      b += '<p class="eva-h">Rendez-vous</p>' + (n ? agendaItems(ag) : '<p class="eva-empty">Aucune intervention dans votre planning.</p>') + agendaExtras(ag);
    } else b += '<p class="eva-note">Agent Planning désactivé.</p>';
    if (d.quotes){ var nq = d.quotes.drafts.length + d.quotes.sent.length; parts.push(nq + ' devis à suivre'); b += '<p class="eva-h">Devis</p><p class="eva-note" style="margin:0">' + d.quotes.drafts.length + ' brouillon(s) · ' + d.quotes.sent.length + ' envoyé(s) sans réponse · ' + d.quotes.accepted_not_invoiced.length + ' accepté(s) à facturer.</p>'; }
    if (d.invoices){ var nf = d.invoices.completed_without_invoice.length + d.invoices.accepted_quotes_without_invoice.length; parts.push(nf + ' facture' + (nf > 1 ? 's' : '') + ' à préparer'); b += '<p class="eva-h">Factures</p><p class="eva-note" style="margin:0">' + nf + ' à préparer · ' + d.invoices.unpaid.length + ' en attente de règlement.</p>'; }
    var att = (d.attention && d.attention.items) || [];
    if (att.length) b += '<p class="eva-h">Actions prioritaires</p>' + attentionList(att);
    var day = ag ? relDay(ag.date) : '';
    var sum = (day ? day + ' : ' : '') + parts.join(', ') + '.';
    sum = sum.charAt(0).toUpperCase() + sum.slice(1);
    return { html: card(null, p.text, sum, b), say: sum };
  }

  // ------------------------------------------------ nouvelles capacités
  var QSTATUS = { DRAFT: ['Brouillon', 'info'], SENT: ['Envoyé', 'wait'], ACCEPTED: ['Accepté', 'ok'], REFUSED: ['Refusé', 'no'], EXPIRED: ['Expiré', 'no'] };
  function periodLabel(d){
    var a = parseIso(d.from), b = parseIso(d.to); if (!a || !b) return '';
    var f = function(x){ return x.toLocaleDateString('fr-FR', { day: 'numeric', month: 'long' }); };
    return d.from === d.to ? 'le ' + f(a) : 'du ' + f(a) + ' au ' + f(b);
  }
  function renderFinance(p, d){
    var sum = 'Facturé ' + periodLabel(d) + ' : ' + eur(d.invoiced_cents) + ' (' + d.invoiced_count + ' facture' + (d.invoiced_count > 1 ? 's' : '') + ' émise' + (d.invoiced_count > 1 ? 's' : '') + '). Encaissé : ' + eur(d.collected_cents) + '.';
    var b = '<ul class="eva-list">' +
      '<li class="eva-item"><div class="eva-main"><b>Facturé (factures émises)</b><span>' + d.invoiced_count + ' facture(s)</span></div><span class="eva-pill info">' + eur(d.invoiced_cents) + '</span></li>' +
      '<li class="eva-item"><div class="eva-main"><b>Encaissé (paiements enregistrés)</b><span>Selon la date de paiement saisie</span></div><span class="eva-pill ok">' + eur(d.collected_cents) + '</span></li>' +
      (d.credit_notes_cents ? '<li class="eva-item"><div class="eva-main"><b>Avoirs</b></div><span class="eva-pill no">−' + eur(d.credit_notes_cents) + '</span></li>' : '') +
      '<li class="eva-item"><div class="eva-main"><b>Reste à encaisser (toutes factures émises)</b></div><span class="eva-pill wait">' + eur(d.outstanding_cents) + '</span></li></ul>' +
      '<p class="eva-note">' + d.completed_count + ' intervention(s) terminée(s), ' + d.quotes_sent_count + ' devis envoyé(s), ' + d.quotes_accepted_count + ' accepté(s) sur la période. ' + (d.drafts_count ? d.drafts_count + ' brouillon(s) de facture non comptés.' : '') + '</p>';
    return { html: card('factures', p.text, sum, b), say: sum };
  }
  function clientChoice(p, clients, intent, extra){
    return '<div class="eva-warn"><p>Plusieurs clients correspondent. Lequel ?</p></div><div class="eva-actions">' + clients.map(function(c){
      return '<button type="button" class="eva-btn sm ghost" data-act="rerun" data-k="' + reg({ intent: intent, args: Object.assign({}, extra || {}, { client_id: c.client_id }), text: p.text + ' → ' + c.name }) + '">' + esc(c.name) + (c.city ? ' · ' + esc(c.city) : '') + '</button>';
    }).join('') + '</div>';
  }
  function renderClientQuotes(p, d){
    var cl = d.clients || [], q = d.quotes || [];
    if (!cl.length){ var s0 = 'Aucun client ne correspond à « ' + (p.args.client || '') + ' ».'; return { html: card('devis', p.text, s0, ''), say: s0 }; }
    if (cl.length > 1) return { html: card('devis', p.text, 'Plusieurs clients correspondent.', clientChoice(p, cl, 'client_quotes')), say: 'Plusieurs clients correspondent. Lequel ?' };
    var name = cl[0].name;
    if (!q.length){ var s1 = name + ' n’a aucun devis.'; return { html: card('devis', p.text, s1, ''), say: s1 }; }
    var last = q[0], st = QSTATUS[last.status] || [last.status, 'info'];
    var sum = 'Dernier devis de ' + name + ' : ' + (last.title || last.reference) + ', ' + eur(last.total_cents) + ' (' + st[0].toLowerCase() + ').';
    var b = '<ul class="eva-list">' + q.map(function(x){ var s2 = QSTATUS[x.status] || [x.status, 'info']; return '<li class="eva-item"><div class="eva-main"><b>' + esc(x.title || 'Devis') + '</b><span>' + esc(x.reference) + ' · ' + esc(new Date(x.created_at).toLocaleDateString('fr-FR')) + '</span></div><span class="eva-pill ' + s2[1] + '">' + esc(s2[0]) + ' · ' + eur(x.total_cents) + '</span></li>'; }).join('') + '</ul>' +
      '<div class="eva-actions"><button type="button" class="eva-btn sm ghost" data-act="goto" data-page="quotes">Ouvrir la rubrique Devis</button></div>';
    return { html: card('devis', p.text, sum, b), say: sum };
  }
  function renderAwaiting(p, d){
    var br = d.booking_requests || [], cb = d.callbacks || [];
    var n = br.length + cb.length;
    var sum = n ? (br.length ? br.length + ' demande' + (br.length > 1 ? 's' : '') + ' de rendez-vous à confirmer' : '') + (br.length && cb.length ? ' et ' : '') + (cb.length ? cb.length + ' demande' + (cb.length > 1 ? 's' : '') + ' de rappel' : '') + '.' : 'Aucun client n’attend de réponse.';
    var b = '';
    if (br.length) b += '<p class="eva-h">Demandes de rendez-vous</p><ul class="eva-list">' + br.map(function(x){
      return '<li class="eva-item"><div class="eva-time">' + esc((parseIso(x.date) || new Date()).toLocaleDateString('fr-FR', { day: '2-digit', month: '2-digit' })) + '<small>' + esc(x.start) + '</small></div><div class="eva-main"><b>' + esc(x.client) + '</b><span>' + esc(x.service) + ' · ' + esc(x.reference) + ' · attend depuis ' + x.waiting_days + ' j</span>' +
        '<div class="eva-actions"><button type="button" class="eva-btn sm cu" data-act="confirm-booking" data-k="' + reg({ booking_id: x.booking_id, idem: key() }) + '">Confirmer</button></div></div></li>';
    }).join('') + '</ul>';
    if (cb.length) b += '<p class="eva-h">Demandes de rappel</p><ul class="eva-list">' + cb.map(function(x){
      return '<li class="eva-item"><div class="eva-main"><b>' + esc(x.name) + '</b>' + (x.phone ? '<a href="tel:' + esc(String(x.phone).replace(/\s/g, '')) + '">' + esc(x.phone) + '</a>' : '') + '<span>Attend depuis ' + x.waiting_days + ' j</span></div></li>';
    }).join('') + '</ul>';
    return { html: card('planning', p.text, sum, b), say: sum };
  }
  var TOOL_STATUS = { disponible: ['Disponible', 'ok'], a_developper: ['À venir', 'wait'], non_realisable: ['Non réalisable', 'no'] };
  function renderCapabilities(p, d){
    var t = d.tools || [], av = t.filter(function(x){ return x.status === 'disponible'; });
    var sum = 'Je sais déjà faire ' + av.length + ' choses ; d’autres arrivent.';
    var b = ['disponible', 'a_developper', 'non_realisable'].map(function(k){
      var l = t.filter(function(x){ return x.status === k; }); if (!l.length) return '';
      return '<p class="eva-h">' + TOOL_STATUS[k][0] + '</p><ul class="eva-list">' + l.map(function(x){
        return '<li class="eva-item"><div class="eva-main"><b>' + esc(x.label) + '</b>' + (x.example ? '<span>« ' + esc(x.example) + ' »</span>' : '') + (x.note ? '<span>' + esc(x.note) + '</span>' : '') + '</div>' +
          (x.level >= 3 && k === 'disponible' ? '<span class="eva-pill wait">Confirmation</span>' : '') + '</li>';
      }).join('') + '</ul>';
    }).join('');
    return { html: card(null, p.text, sum, b), say: sum };
  }
  var NOT_YET_LABEL = { client_create: 'créer ou modifier une fiche client', service_create: 'ajouter une prestation au catalogue', quote_send: 'envoyer un devis à un client', booking_cancel: 'annuler ou refuser un rendez-vous', booking_create: 'créer un rendez-vous pour un client' };
  function notYet(p){
    var what = NOT_YET_LABEL[p.args.tool] || 'faire cette action';
    var s1 = 'Je ne sais pas encore ' + what + '.';
    addCard(card(null, p.text, s1, '<p class="eva-note">Cette action est prévue dans la prochaine étape d’EVA : elle nécessite d’abord une fonction sécurisée côté serveur. En attendant, utilisez la rubrique habituelle de l’administration.</p>' +
      '<div class="eva-actions"><button type="button" class="eva-btn sm ghost" data-act="dev-note" data-k="' + reg({ text: 'EVA : permettre de ' + what + ' (« ' + p.text + ' »)' }) + '">Ajouter à mes demandes d’évolution</button></div>'));
    speak(s1);
  }
  function devRequestCard(p){
    var txt = p.args.text || p.text;
    addCard(card(null, p.text, 'Je note cette demande d’évolution ?', '<p class="eva-note" style="margin-top:0">« ' + esc(txt) + ' »</p><p class="eva-note">Elle sera transmise plus tard à un agent de développement séparé, qui préparera une proposition sur une branche dédiée. Rien n’est jamais déployé sans votre accord.</p>' +
      '<div class="eva-actions"><button type="button" class="eva-btn cu" data-act="dev-save" data-k="' + reg({ text: txt }) + '">Enregistrer la demande</button></div><p class="eva-msg" data-role="msg" hidden></p>'));
    speak('Je note cette demande d’évolution ? Touchez Enregistrer pour confirmer.');
  }
  function invoiceLast(p, holder){
    return rpc('eva_run', { p_intent: 'last_intervention', p_args: {}, p_command: p.text }).then(function(r){
      var d = r.data;
      if (!d){ holder.outerHTML = card('factures', p.text, 'Aucune intervention terminée dans votre planning.', ''); speak('Aucune intervention terminée.'); return; }
      var head = (d.service || 'Intervention') + ' chez ' + d.client + ' le ' + (parseIso(d.date) || new Date()).toLocaleDateString('fr-FR');
      if (d.invoice){
        var s2 = 'Votre dernière intervention (' + head + ') a déjà une facture ' + (d.invoice.status === 'DRAFT' ? 'en brouillon' : 'émise') + ' : ' + (d.invoice.reference || '') + '.';
        holder.outerHTML = card('factures', p.text, s2, d.invoice.status === 'DRAFT' ? '<div class="eva-actions"><button type="button" class="eva-btn sm cu" data-act="issue" data-k="' + reg({ invoice_id: d.invoice.invoice_id, idem: key() }) + '">Émettre cette facture</button><button type="button" class="eva-btn sm ghost" data-act="goto" data-page="invoices">Ouvrir la rubrique Factures</button></div>' : '');
        speak(s2); return;
      }
      holder.outerHTML = card('factures', p.text, 'Dernière intervention : ' + head + ' (' + eur(d.total_cents) + '). Je prépare la proposition de brouillon.', '');
      return propose('invoice_draft', { source: 'booking', id: d.booking_id }, key(), null).then(function(){ speak('Proposition de brouillon de facture prête : vérifiez puis confirmez.'); });
    }, function(e){ holder.outerHTML = errorCard(errText(e), p.text); });
  }
  function moveBooking(p, holder){
    return rpc('eva_run', { p_intent: 'agenda', p_args: { date: p.args.date }, p_command: p.text }).then(function(r){
      var d = r.data, list = (d.interventions || []).filter(function(x){ return x.status === 'PENDING' || x.status === 'CONFIRMED'; });
      if (p.args.client){
        var w = I.norm(p.args.client).replace(/^(monsieur|madame|mme|m\.)\s+/, '').split(' ').filter(Boolean);
        list = list.filter(function(x){ var n = I.norm(x.client); return w.every(function(k){ return n.indexOf(k) !== -1; }); });
      }
      if (!list.length){ var s0 = relDay(d.date) + ' : aucun rendez-vous à déplacer.'; holder.outerHTML = card('planning', p.text, s0, ''); speak(s0); return; }
      var x = p.args.which === 'last' ? list[list.length - 1] : (list[p.args.which] || list[0]);
      holder.outerHTML = card('planning', p.text, 'Rendez-vous concerné : ' + x.start + ', ' + x.client + ' (' + x.service + ').', '<p class="eva-note" style="margin-top:0">' + esc(dayLabel(d.date)) + ' · ' + esc(x.reference) + '</p>');
      var from = parseIso(d.date) > new Date() ? parseIso(d.date) : new Date(); var to = new Date(from); to.setDate(to.getDate() + 13);
      return rpc('eva_run', { p_intent: 'free_slots', p_args: { from: I.iso(from), to: I.iso(to), duration: x.duration_minutes }, p_command: 'Créneaux pour déplacer ' + x.reference }).then(function(r2){
        var out = renderSlots({ text: 'Déplacer ' + x.reference }, r2.data, { booking_id: x.booking_id, reference: x.reference });
        addCard(out.html); speak('Choisissez le nouveau créneau pour ' + x.client + '.');
      });
    }, function(e){ holder.outerHTML = errorCard(errText(e), p.text); });
  }
  function payForm(btn, o){
    var li = btn.closest('.eva-main'); if (li.querySelector('.eva-pay')) return;
    var today = I.iso(new Date());
    li.insertAdjacentHTML('beforeend', '<div class="eva-pay eva-set" style="margin-top:10px">' +
      '<label class="eva-field">Montant reçu (€)<input type="number" inputmode="decimal" min="0.01" step="0.01" data-role="amount" value="' + ((o.remaining || 0) / 100).toFixed(2) + '"></label>' +
      '<label class="eva-field">Moyen<select data-role="method"><option value="">— Choisir —</option><option value="virement">Virement</option><option value="cheque">Chèque</option><option value="especes">Espèces</option><option value="carte">Carte bancaire</option><option value="autre">Autre</option></select></label>' +
      '<label class="eva-field">Date du paiement<input type="date" data-role="paid_on" value="' + today + '" max="' + today + '"></label>' +
      '<div class="eva-actions" style="margin-top:0"><button type="button" class="eva-btn sm cu" data-act="pay" data-k="' + reg({ invoice_id: o.invoice_id, idem: key() }) + '">Préparer l’enregistrement</button></div></div>');
  }

  // -------------------------------------------------------- propositions
  function proposalCard(pr, fresh){
    var l3 = pr.level === 3;
    var acts = pr.status === 'PENDING'
      ? (l3 ? '<label class="eva-check"><input type="checkbox" data-role="ack"> <span>J’ai lu les conséquences et je confirme cette action engageante.</span></label>' : '') +
        '<div class="eva-actions"><button type="button" class="eva-btn cu" data-act="confirm" data-id="' + esc(pr.id || pr.proposal_id) + '"' + (l3 ? ' disabled' : '') + '>' + (l3 ? 'Confirmer l’action' : 'Confirmer') + '</button>' +
        '<button type="button" class="eva-btn ghost" data-act="cancel" data-id="' + esc(pr.id || pr.proposal_id) + '">Annuler</button></div>'
      : '<p class="eva-note">' + esc({ EXECUTED: 'Exécutée', CANCELLED: 'Annulée', FAILED: 'Échec : ' + (pr.error || ''), EXPIRED: 'Expirée' }[pr.status] || pr.status) + '</p>';
    return '<div class="eva-card eva-prop" data-prop="' + esc(pr.id || pr.proposal_id) + '"><div class="eva-card-head"><span class="eva-agent">' + esc(AGENT[pr.agent] || 'EVA') + '</span>' +
      '<span class="eva-lvl ' + (l3 ? 'l3' : 'l2') + '">' + (l3 ? 'Action engageante' : 'Préparation') + '</span></div>' +
      '<p class="eva-sum">' + esc(pr.title) + '</p><ul class="eva-cons">' + (pr.consequences || []).map(function(c){ return '<li>' + esc(c) + '</li>'; }).join('') + '</ul>' + acts + '<p class="eva-msg" data-role="msg" hidden></p></div>';
  }
  function propose(kind, payload, idem, btn){
    if (btn) btn.disabled = true;
    return rpc('eva_propose', { p_kind: kind, p_payload: payload, p_idem_key: idem }).then(function(r){
      if (r.duplicate) return loadOverview().then(function(){ setTab('proposals'); });
      var agent = (kind === 'reschedule' || kind === 'booking_confirm') ? 'planning' : kind === 'quote_draft' ? 'devis' : 'factures';
      addCard(proposalCard({ proposal_id: r.proposal_id, level: r.level, agent: agent, title: r.title, consequences: r.consequences, status: 'PENDING' }, true));
      updateBadge();
    }, function(e){ if (btn) btn.disabled = false; addCard(errorCard(errText(e))); });
  }
  function confirmProp(id, btn){
    var cardEl = btn.closest('[data-prop]'), msg = cardEl.querySelector('[data-role="msg"]');
    cardEl.querySelectorAll('button').forEach(function(b){ b.disabled = true; });
    rpc('eva_confirm_proposal', { p_id: id, p_confirm: true }).then(function(r){
      if (!r.ok){ msg.hidden = false; msg.className = 'eva-msg no'; msg.textContent = r.error || 'Action non réalisée.'; return; }
      var res = r.result || {}, txt = 'Fait.', page = null;
      if (res.payment){ txt = 'Paiement enregistré.' + (res.invoice_status === 'PAID' ? ' La facture est entièrement réglée.' : ' La facture reste partiellement réglée.'); page = 'invoices'; }
      else if (res.issued){ txt = 'Facture émise : ' + (res.reference || '') + '. Elle est désormais définitive.'; page = 'invoices'; }
      else if (res.quote_id){ txt = 'Brouillon de devis ' + (res.reference || '') + ' créé. Complétez-le puis envoyez-le depuis la rubrique Devis.'; page = 'quotes'; }
      else if (res.invoice_id){ txt = 'Brouillon de facture prêt' + (res.reference ? ' (' + res.reference + ')' : '') + '. Vérifiez-le dans la rubrique Factures avant toute émission.'; page = 'invoices'; }
      else if (res.confirmed){ txt = 'Rendez-vous confirmé. Le client reçoit l’e-mail de confirmation, le rendez-vous est ajouté à Apple Calendar.'; page = 'planning'; }
      else if (res.booking_id){ txt = 'Rendez-vous déplacé au ' + dayLabel(res.date) + ' à ' + res.start + '. Le client est prévenu, le calendrier est mis à jour.'; page = 'planning'; }
      cardEl.querySelectorAll('.eva-actions, .eva-check').forEach(function(x){ x.remove(); });
      msg.hidden = false; msg.className = 'eva-msg ok'; msg.textContent = txt; speak(txt);
      loadToday();
      if (page) msg.insertAdjacentHTML('afterend', '<div class="eva-actions"><button type="button" class="eva-btn sm ghost" data-act="goto" data-page="' + page + '">Ouvrir</button></div>');
      updateBadge();
    }, function(e){ msg.hidden = false; msg.className = 'eva-msg no'; msg.textContent = errText(e); cardEl.querySelectorAll('[data-act="cancel"]').forEach(function(b){ b.disabled = false; }); });
  }
  function cancelProp(id, btn){
    var cardEl = btn.closest('[data-prop]'), msg = cardEl.querySelector('[data-role="msg"]');
    rpc('eva_cancel_proposal', { p_id: id }).then(function(){
      cardEl.querySelectorAll('.eva-actions, .eva-check').forEach(function(x){ x.remove(); });
      msg.hidden = false; msg.className = 'eva-msg'; msg.textContent = 'Proposition annulée : rien n’a été modifié.';
      updateBadge();
    }, function(e){ msg.hidden = false; msg.className = 'eva-msg no'; msg.textContent = errText(e); });
  }

  // ------------------------------------------- propositions, historique, réglages
  function updateBadge(){
    rpc('eva_overview').then(function(o){
      state.overview = o;
      var n = (o.proposals || []).filter(function(p){ return p.status === 'PENDING'; }).length, b = root.querySelector('#evaPropBadge');
      b.textContent = n; b.hidden = !n;
    }, function(){});
  }
  function loadOverview(){
    return rpc('eva_overview').then(function(o){
      state.overview = o;
      renderProposals(o); renderHistory(o); renderSettings(o);
      var n = (o.proposals || []).filter(function(p){ return p.status === 'PENDING'; }).length, b = root.querySelector('#evaPropBadge');
      b.textContent = n; b.hidden = !n;
    }, function(e){
      ['proposals', 'history', 'settings'].forEach(function(k){ root.querySelector('[data-pane="' + k + '"]').innerHTML = errorCard(errText(e)); });
    });
  }
  function renderProposals(o){
    var pend = (o.proposals || []).filter(function(p){ return p.status === 'PENDING'; }), done = (o.proposals || []).filter(function(p){ return p.status !== 'PENDING'; }).slice(0, 10);
    root.querySelector('[data-pane="proposals"]').innerHTML =
      '<p class="eva-h" style="margin-top:4px">À valider</p>' + (pend.length ? '<div class="eva-feed" style="margin-top:0">' + pend.map(function(p){ return proposalCard(p); }).join('') + '</div>' : '<p class="eva-empty">Aucune proposition en attente.</p>') +
      (done.length ? '<p class="eva-h">Terminées</p><div class="eva-feed" style="margin-top:0">' + done.map(function(p){ return proposalCard(p); }).join('') + '</div>' : '');
  }
  var OUT = { ok: 'Réponse', empty: 'Aucune donnée', refused: 'Refusé', error: 'Erreur', proposed: 'Proposé', confirmed: 'Confirmé', cancelled: 'Annulé', failed: 'Échec', settings: 'Réglages' };
  var INT = { agenda: 'Interventions', free_slots: 'Créneaux libres', conflicts: 'Conflits', find_client: 'Recherche client', quote_estimate: 'Chiffrage', quotes_pending: 'Devis', invoices_todo: 'Factures', attention: 'Attention', brief: 'Ma journée' };
  function renderHistory(o){
    var j = o.journal || [];
    root.querySelector('[data-pane="history"]').innerHTML = '<p class="eva-h" style="margin-top:4px">Vos dernières actions (' + (o.today_count || 0) + ' aujourd’hui)</p>' +
      (j.length ? '<ul class="eva-list eva-hist">' + j.map(function(x){
        var t = new Date(x.at), when = t.toLocaleDateString('fr-FR', { day: '2-digit', month: '2-digit' }) + ' ' + t.toLocaleTimeString('fr-FR', { hour: '2-digit', minute: '2-digit' });
        var label = x.command || INT[x.intent] || String(x.intent || '').replace(/^(propose|confirm|cancel):/, function(m, a){ return { propose: 'Proposition ', confirm: 'Confirmation ', cancel: 'Annulation ' }[a]; });
        return '<li class="eva-item"><time>' + esc(when) + '</time><div class="eva-main"><b>' + esc(label) + '</b><span>' + esc(AGENT[x.agent] || 'EVA') + '</span></div><span class="eva-pill ' + ({ ok: 'ok', confirmed: 'ok', empty: 'info', proposed: 'info', settings: 'info', cancelled: 'wait' }[x.outcome] || 'no') + '">' + esc(OUT[x.outcome] || x.outcome) + '</span></li>';
      }).join('') + '</ul>' : '<p class="eva-empty">Aucune action pour le moment.</p>') +
      ((o.dev_requests || []).length ? '<p class="eva-h">Demandes d’évolution</p><ul class="eva-list">' + o.dev_requests.map(function(x){
        return '<li class="eva-item"><div class="eva-main"><b>' + esc(x.request) + '</b><span>' + esc(new Date(x.at).toLocaleDateString('fr-FR')) + '</span></div><span class="eva-pill info">' + esc({ NOUVELLE: 'Nouvelle', EN_ANALYSE: 'En analyse', PROPOSEE: 'Proposée', REFUSEE: 'Refusée', TERMINEE: 'Terminée' }[x.status] || x.status) + '</span></li>';
      }).join('') + '</ul>' : '');
  }
  var DAY_NAMES = ['Lundi', 'Mardi', 'Mercredi', 'Jeudi', 'Vendredi', 'Samedi', 'Dimanche'];
  function renderSettings(o){
    var s = o.settings || {}, w = o.work || {}, v = o.vat || {}, ag = s.agents || {}, tts = false;
    try { tts = localStorage.getItem(TTS_KEY) !== '0'; } catch (e){ tts = true; }
    var wh = w.work_hours || {};
    var days = DAY_NAMES.map(function(n, i){
      var r = wh[String(i + 1)] || [];
      var row = function(k){ var x = r[k] || ['', '']; return '<span class="eva-range"><input type="time" step="300" aria-label="' + n + ' plage ' + (k + 1) + ' début" data-wh="' + (i + 1) + '-' + k + '-0" value="' + esc(x[0]) + '">–<input type="time" step="300" aria-label="' + n + ' plage ' + (k + 1) + ' fin" data-wh="' + (i + 1) + '-' + k + '-1" value="' + esc(x[1]) + '"></span>'; };
      return '<div class="eva-day"><b>' + n + '</b><div class="eva-ranges">' + row(0) + row(1) + '</div></div>';
    }).join('');
    var VAT = { franchise_base: 'Franchise en base (TVA non applicable, art. 293 B du CGI)', assujetti: 'Assujetti à la TVA' };
    root.querySelector('[data-pane="settings"]').innerHTML =
      '<p class="eva-h" style="margin-top:4px">EVA</p><div class="eva-set">' +
        '<label class="eva-toggle"><span>EVA activée</span><input type="checkbox" data-set="enabled"' + (s.enabled ? ' checked' : '') + '></label>' +
        ['planning', 'devis', 'factures'].map(function(k){ return '<label class="eva-toggle"><span>' + AGENT[k] + '</span><input type="checkbox" data-set="agent" data-agent="' + k + '"' + (ag[k] ? ' checked' : '') + '></label>'; }).join('') +
        '<label class="eva-toggle"><span>Lire les réponses à voix haute après une dictée</span><input type="checkbox" data-set="tts"' + (tts ? ' checked' : '') + '></label>' +
        '<p class="eva-msg" data-role="set-msg" hidden></p>' +
      '</div>' +
      '<p class="eva-h">Horaires de travail</p><p class="eva-note" style="margin-top:-4px">Laissez une plage vide pour la retirer, les deux pour un jour non travaillé. Ces horaires s’appliquent aussi aux créneaux proposés à vos clients sur le site.</p>' +
      '<div class="eva-days">' + days + '</div>' +
      '<label class="eva-field" style="margin-top:10px">Marge de trajet entre deux interventions (minutes)<input type="number" min="0" max="180" step="5" data-role="margin" value="' + esc(w.travel_margin_minutes != null ? w.travel_margin_minutes : 30) + '"></label>' +
      '<div class="eva-actions"><button type="button" class="eva-btn cu" data-act="save-hours">Enregistrer les horaires</button></div><p class="eva-msg" data-role="hours-msg" hidden></p>' +
      '<p class="eva-h">Régime de TVA</p>' +
      '<p class="eva-note" style="margin-top:-4px">Actuel : ' + esc(VAT[v.vat_regime] || 'non renseigné') + (v.vat_regime === 'assujetti' && v.default_vat_rate != null ? ' — taux par défaut ' + esc(String(v.default_vat_rate).replace('.', ',')) + ' %' : '') + '. ' +
        (v.confirmed_at ? 'Confirmé le ' + esc(new Date(v.confirmed_at).toLocaleDateString('fr-FR')) + '.' : '<b style="color:#F7CF84">Non confirmé : aucune facture définitive possible.</b>') + '</p>' +
      '<div class="eva-set">' +
        '<label class="eva-field">Régime<select data-role="vat-regime"><option value="">— Choisir —</option><option value="franchise_base"' + (v.vat_regime === 'franchise_base' ? ' selected' : '') + '>' + VAT.franchise_base + '</option><option value="assujetti"' + (v.vat_regime === 'assujetti' ? ' selected' : '') + '>' + VAT.assujetti + '</option></select></label>' +
        '<label class="eva-field" data-role="vat-rate-wrap"' + (v.vat_regime === 'assujetti' ? '' : ' hidden') + '>Taux par défaut<select data-role="vat-rate"><option value="20"' + (Number(v.default_vat_rate) === 20 ? ' selected' : '') + '>20 %</option><option value="10"' + (Number(v.default_vat_rate) === 10 ? ' selected' : '') + '>10 %</option><option value="5.5"' + (Number(v.default_vat_rate) === 5.5 ? ' selected' : '') + '>5,5 %</option></select></label>' +
        '<label class="eva-check"><input type="checkbox" data-role="vat-ack"> <span>Je confirme que ce régime correspond à ma situation (à vérifier avec mon comptable). Il sera appliqué à mes factures.</span></label>' +
        '<div class="eva-actions" style="margin-top:0"><button type="button" class="eva-btn cu" data-act="save-vat" disabled>Confirmer le régime de TVA</button></div><p class="eva-msg" data-role="vat-msg" hidden></p>' +
      '</div>' +
      '<p class="eva-h">Micro</p><p class="eva-note" style="margin-top:-4px">' + esc(micInfo()) + '</p>';
  }
  function micInfo(){
    return SR ? 'La dictée utilise la reconnaissance vocale de votre navigateur (Apple sur iPhone et iPad). EVA n’écoute que lorsque vous touchez le micro, jamais en arrière-plan.'
              : 'La dictée n’est pas disponible dans ce navigateur : utilisez le micro de votre clavier. EVA n’écoute jamais en arrière-plan.';
  }
  function saveHours(btn){
    var pane = root.querySelector('[data-pane="settings"]'), msg = pane.querySelector('[data-role="hours-msg"]'), out = {}, bad = false;
    for (var d = 1; d <= 7; d++){
      out[d] = [];
      for (var k = 0; k < 2; k++){
        var a = pane.querySelector('[data-wh="' + d + '-' + k + '-0"]').value, b = pane.querySelector('[data-wh="' + d + '-' + k + '-1"]').value;
        if (!a && !b) continue;
        if (!a || !b || a >= b){ bad = true; continue; }
        out[d].push([a.slice(0, 5), b.slice(0, 5)]);
      }
      out[d].sort(function(x, y){ return x[0] < y[0] ? -1 : 1; });
    }
    var margin = Number(pane.querySelector('[data-role="margin"]').value);
    msg.hidden = false;
    if (bad){ msg.className = 'eva-msg no'; msg.textContent = 'Chaque plage doit avoir un début et une fin, la fin après le début.'; return; }
    btn.disabled = true;
    rpc('admin_set_work_hours', { p_work_hours: out, p_travel_margin: margin }).then(function(){
      btn.disabled = false; msg.className = 'eva-msg ok'; msg.textContent = 'Horaires enregistrés.';
    }, function(e){ btn.disabled = false; msg.className = 'eva-msg no'; msg.textContent = errText(e); });
  }
  function saveVat(btn){
    var pane = root.querySelector('[data-pane="settings"]'), msg = pane.querySelector('[data-role="vat-msg"]');
    var regime = pane.querySelector('[data-role="vat-regime"]').value, rate = regime === 'assujetti' ? Number(pane.querySelector('[data-role="vat-rate"]').value) : null;
    msg.hidden = false;
    if (!regime){ msg.className = 'eva-msg no'; msg.textContent = 'Choisissez un régime.'; return; }
    btn.disabled = true;
    rpc('admin_confirm_vat_regime', { p_regime: regime, p_rate: rate }).then(function(){
      msg.className = 'eva-msg ok'; msg.textContent = 'Régime de TVA confirmé.'; loadOverview();
    }, function(e){ btn.disabled = false; msg.className = 'eva-msg no'; msg.textContent = errText(e); });
  }
  function saveSetting(el){
    var pane = root.querySelector('[data-pane="settings"]'), msg = pane.querySelector('[data-role="set-msg"]');
    if (el.getAttribute('data-set') === 'tts'){ try { localStorage.setItem(TTS_KEY, el.checked ? '1' : '0'); } catch (e){} return; }
    var p = el.getAttribute('data-set') === 'enabled' ? { p_enabled: el.checked, p_agents: {} } : { p_enabled: null, p_agents: (function(){ var o = {}; o[el.getAttribute('data-agent')] = el.checked; return o; })() };
    rpc('eva_set_settings', p).then(function(){ msg.hidden = false; msg.className = 'eva-msg ok'; msg.textContent = 'Réglage enregistré.'; loadToday(); },
      function(e){ el.checked = !el.checked; msg.hidden = false; msg.className = 'eva-msg no'; msg.textContent = errText(e); });
  }

  // ------------------------------------------------------------ événements
  function onChange(e){
    var t = e.target;
    if (t.matches('[data-set]')) return saveSetting(t);
    if (t.matches('[data-role="ack"]')){ var b = t.closest('[data-prop]').querySelector('[data-act="confirm"]'); if (b) b.disabled = !t.checked; return; }
    if (t.matches('[data-role="vat-regime"]')){ root.querySelector('[data-role="vat-rate-wrap"]').hidden = t.value !== 'assujetti'; return; }
    if (t.matches('[data-role="vat-ack"]')){ root.querySelector('[data-act="save-vat"]').disabled = !t.checked; }
  }
  function onClick(e){
    var b = e.target.closest('[data-act]'); if (!b || b.disabled) return;
    var act = b.getAttribute('data-act'), k = b.getAttribute('data-k'), o = k ? state.reg[k] : null;
    if (act === 'close') return close();
    if (act === 'tab') return setTab(b.getAttribute('data-tab'));
    if (act === 'run') return run(b.getAttribute('data-cmd'), false);
    if (act === 'goto'){ var page = b.getAttribute('data-page'); close(); if (window.admShowPage) window.admShowPage(page); return; }
    if (act === 'move' && o){
      b.disabled = true;
      var from = new Date(); from.setDate(from.getDate() + 1);
      var to = new Date(from); to.setDate(to.getDate() + 13);
      return rpc('eva_run', { p_intent: 'free_slots', p_args: { from: I.iso(from), to: I.iso(to), duration: o.duration }, p_command: 'Créneaux pour déplacer ' + o.reference }).then(function(r){
        addCard(renderSlots({ text: 'Déplacer ' + o.reference }, r.data, o).html); b.disabled = false;
      }, function(err){ b.disabled = false; addCard(errorCard(errText(err))); });
    }
    if (act === 'pick' && o) return propose('reschedule', { booking_id: o.booking_id, date: o.date, start: o.start }, o.idem, b);
    if (act === 'invoice' && o) return propose('invoice_draft', { source: o.source, id: o.id }, o.idem, b);
    if (act === 'quote' && o){
      var c = b.closest('.eva-card'), sel = c.querySelector('input[name="' + o.group + '"]:checked');
      if (!sel){ addCard(errorCard('Choisissez une prestation à prix fixe.')); return; }
      var m = o.matches[Number(sel.value)], km = c.querySelector('[data-role="km"]');
      var dist = o.distance != null ? o.distance : (km && km.value !== '' ? Number(km.value) : null);
      return propose('quote_draft', { client_id: o.client_id, items: [{ kind: m.kind, id: m.id }], distance_km: dist }, o.idem, b);
    }
    if (act === 'rerun' && o) return runOne({ intent: o.intent, args: o.args, text: o.text }, o.text);
    if (act === 'confirm-booking' && o) return propose('booking_confirm', { booking_id: o.booking_id }, o.idem, b);
    if (act === 'issue' && o) return propose('invoice_issue', { invoice_id: o.invoice_id }, o.idem, b);
    if (act === 'pay-form' && o) return payForm(b, o);
    if (act === 'pay' && o){
      var f = b.closest('.eva-pay'), amt = Math.round(Number(String(f.querySelector('[data-role="amount"]').value).replace(',', '.')) * 100);
      var meth = f.querySelector('[data-role="method"]').value, on = f.querySelector('[data-role="paid_on"]').value;
      if (!(amt > 0) || !meth || !on){ addCard(errorCard('Indiquez le montant, le moyen et la date du paiement reçu.')); return; }
      return propose('invoice_payment', { invoice_id: o.invoice_id, amount_cents: amt, method: meth, paid_on: on }, o.idem, b);
    }
    if (act === 'dev-note' && o) return devRequestCard({ text: o.text, args: { text: o.text } });
    if (act === 'dev-save' && o){
      b.disabled = true; var m = b.closest('.eva-card').querySelector('[data-role="msg"]');
      return rpc('eva_add_dev_request', { p_request: o.text }).then(function(){ m.hidden = false; m.className = 'eva-msg ok'; m.textContent = 'Demande enregistrée dans vos évolutions (onglet Historique).'; speak('Demande enregistrée.'); },
        function(e){ b.disabled = false; m.hidden = false; m.className = 'eva-msg no'; m.textContent = errText(e); });
    }
    if (act === 'stop-mic') return stopMic();
    if (act === 'confirm') return confirmProp(b.getAttribute('data-id'), b);
    if (act === 'cancel') return cancelProp(b.getAttribute('data-id'), b);
    if (act === 'save-hours') return saveHours(b);
    if (act === 'save-vat') return saveVat(b);
  }

  // ----------------------------------------------------------------- micro
  var SR = window.SpeechRecognition || window.webkitSpeechRecognition || null, rec = null;
  function stopMic(){ if (rec){ try { rec.abort(); } catch (e){} } setListening(false); }
  function listenVeil(){
    var v = root.querySelector('#evaListen');
    if (!v){
      v = document.createElement('div'); v.id = 'evaListen'; v.className = 'eva-listen'; v.setAttribute('role', 'status'); v.setAttribute('aria-live', 'polite');
      v.innerHTML = '<div class="eva-orb"><span class="eva-ring" id="evaRing"></span><img src="' + (location.protocol === 'file:' ? '' : '/') + 'images/brand/hayeva-logo-sm.png" alt="" width="900" height="607"></div>' +
        '<p class="eva-listen-t">EVA vous écoute…</p><p class="eva-listen-q" id="evaListenQ"></p>' +
        '<button type="button" class="eva-btn ghost" data-act="stop-mic">Arrêter le micro</button>';
      root.appendChild(v);
    }
    return v;
  }
  function pulse(level){ var r = root && root.querySelector('#evaRing'); if (r) r.style.setProperty('--lvl', String(Math.max(0, Math.min(1, level)))); }
  function setListening(on){
    state.listening = on;
    if (micBtn){ micBtn.setAttribute('aria-pressed', on ? 'true' : 'false'); micBtn.setAttribute('aria-label', on ? 'Arrêter la dictée' : 'Dicter une commande'); }
    if (!root) return;
    var v = listenVeil(); v.classList.toggle('is-on', on); v.hidden = !on;
    if (!on) pulse(0); else root.querySelector('#evaListenQ').textContent = '';
  }
  function toggleMic(){
    if (!SR){ hintEl.textContent = 'Dictée indisponible ici : touchez le champ puis le micro de votre clavier.'; input.focus(); return; }
    if (state.listening) return stopMic();
    rec = new SR(); rec.lang = 'fr-FR'; rec.interimResults = true; rec.maxAlternatives = 1; rec.continuous = false;
    var finalText = '';
    rec.onresult = function(ev){
      var txt = ''; for (var i = 0; i < ev.results.length; i++){ txt += ev.results[i][0].transcript; if (ev.results[i].isFinal) finalText = txt; }
      input.value = txt;
      var q = root.querySelector('#evaListenQ'); if (q) q.textContent = '« ' + txt + ' »';
      // L'anneau réagit à la parole reconnue (chaque nouveau fragment = une impulsion).
      pulse(0.55 + Math.min(0.45, (txt.length % 9) / 18)); clearTimeout(state.pulseT); state.pulseT = setTimeout(function(){ pulse(0.15); }, 260);
    };
    rec.onspeechstart = function(){ pulse(0.6); };
    rec.onaudiostart = function(){ pulse(0.2); };
    rec.onerror = function(ev){ setListening(false); hintEl.textContent = ev.error === 'not-allowed' || ev.error === 'service-not-allowed' ? 'Micro refusé : autorisez-le dans les réglages du navigateur, ou utilisez le micro du clavier.' : 'Dictée interrompue. Réessayez ou tapez votre commande.'; };
    rec.onend = function(){ setListening(false); var v = (finalText || input.value).trim(); hintEl.textContent = ''; if (v){ input.value = ''; run(v, true); } };
    try { rec.start(); setListening(true); hintEl.textContent = 'Je vous écoute… (touchez à nouveau pour arrêter)'; } catch (e){ setListening(false); }
  }

  window.EVA = { open: open, close: close, run: function(t){ if (!root) build(); return run(t, false); } };
})();
