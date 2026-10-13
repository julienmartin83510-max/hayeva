// =====================================================================
// EVA — assistante de gestion HAYEVA (V1 + phase 2, sans IA payante).
// - Comprend une commande en français grâce à EVAIntents (règles locales,
//   aucune donnée envoyée à un service d'IA).
// - Interroge le serveur via eva_run (rôle administrateur revérifié,
//   données RÉELLES du planning, des devis et des factures) et eva_query
//   (fiches clients, catalogue, statistiques, parrainage, fidélité…).
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
  var root, feed, input, micBtn, hintEl, state = { tab: 'today', overview: null, reg: {}, seq: 0, voice: false, listening: false, convo: false, speaking: false, pending: 0, last: null };
  var TTS_KEY = 'hv_eva_tts', HF_KEY = 'hv_eva_handsfree';

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
  var AGENT = { planning: 'Agent Planning', devis: 'Agent Devis', factures: 'Agent Factures', clients: 'Agent Clients', fidelite: 'Agent Fidélité' };
  var ERR = {
    EVA_DESACTIVEE: 'EVA est désactivée dans les réglages.',
    TROP_DE_DEMANDES: 'Trop de demandes en une minute : patientez un instant.',
    LIMITE_JOURNALIERE: 'Limite quotidienne de commandes atteinte.',
    DATE_INVALIDE: 'Date non reconnue.',
    PERIODE_INVALIDE: 'Période trop longue : limitez-la à un mois.',
    INTENTION_INCONNUE: 'Commande non prise en charge.',
    DOSSIER_OCCUPE: 'Une proposition est déjà en attente sur ce dossier : confirmez-la ou annulez-la d’abord (onglet Propositions).',
    CONFIRMATION_REQUISE: 'Confirmation explicite requise.',
    PROPOSITION_INCONNUE: 'Action non prise en charge.',
    REAUTH_REQUISE: 'Action sensible : confirmez votre identité pour continuer.'
  };
  function errText(e){
    var m = String((e && (e.message || e.details)) || e || '');
    if (/PGRST202|Could not find the function|does not exist/i.test(m)) return 'EVA n’est pas encore installée sur la base de données (migrations 0135 et 0136 à appliquer).';
    var a = /AGENT_DESACTIVE:(\w+)/.exec(m); if (a) return (AGENT[a[1]] || 'Cet agent') + ' est désactivé dans les réglages.';
    for (var k in ERR) if (m.indexOf(k) !== -1) return ERR[k];
    if (/réservée|42501|permission/i.test(m)) return 'Action réservée à l’administrateur connecté.';
    if (/JWT|session/i.test(m)) return 'Votre session a expiré : reconnectez-vous.';
    if (/Failed to fetch|NetworkError|Load failed|network|ERR_INTERNET|timeout/i.test(m)) return 'Connexion interrompue : vérifiez le réseau, puis reposez la question.';
    return m && m.length < 220 ? m : 'EVA n’a pas pu répondre. Réessayez dans un instant.';
  }
  function rpc(name, args){
    var c = sb(); if (!c) return Promise.reject(new Error('Service indisponible.'));
    state.pending++; updVoice();
    var fin = function(){ state.pending = Math.max(0, state.pending - 1); updVoice(); };
    return c.rpc(name, args || {}).then(function(r){ fin(); if (r.error) throw r.error; return r.data; }, function(e){ fin(); throw e; });
  }
  // Actions sensibles : si le serveur exige une connexion récente (REAUTH_REQUISE),
  // EVA demande de confirmer l'identité puis relance UNE fois la même demande.
  function rpcAuth(name, args){
    return rpc(name, args).catch(function(e){
      if (!/REAUTH_REQUISE/.test(String((e && (e.message || e.details)) || e))) throw e;
      return reauth().then(function(){ return rpc(name, args); });
    });
  }
  function reauth(){
    return new Promise(function(resolve, reject){
      var c = sb(); if (!c) return reject(new Error('Service indisponible.'));
      c.auth.getUser().then(function(u){
        var email = u && u.data && u.data.user && u.data.user.email;
        if (!email) return reject(new Error('Votre session a expiré : reconnectez-vous.'));
        var v = document.createElement('div'); v.className = 'eva-reauth'; v.setAttribute('role', 'dialog'); v.setAttribute('aria-modal', 'true'); v.setAttribute('aria-labelledby', 'evaReauthT');
        v.innerHTML = '<form class="eva-reauth-box" autocomplete="on">' +
          '<img src="' + (location.protocol === 'file:' ? '' : '/') + 'images/brand/hayeva-logo-sm.png" alt="" width="900" height="607">' +
          '<p class="eva-h" id="evaReauthT" style="margin:0">Confirmer mon identité</p>' +
          '<p class="eva-note" style="margin:0">Action sensible : reconnectez-vous pour la valider. Sur iPhone, touchez le champ mot de passe : si votre mot de passe est enregistré dans le trousseau iCloud, iOS le propose avec Face ID.</p>' +
          '<input type="email" name="username" autocomplete="username" value="' + esc(email) + '" readonly class="eva-reauth-user" aria-label="Identifiant">' +
          '<label class="eva-field">Mot de passe<input type="password" name="password" autocomplete="current-password" required data-role="reauth-pw"></label>' +
          '<p class="eva-msg no" data-role="reauth-msg" hidden></p>' +
          '<div class="eva-actions" style="margin-top:0"><button type="submit" class="eva-btn cu">Confirmer</button><button type="button" class="eva-btn ghost" data-role="reauth-cancel">Annuler</button></div></form>';
        root.appendChild(v);
        var f = v.querySelector('form'), pw = v.querySelector('[data-role="reauth-pw"]'), m = v.querySelector('[data-role="reauth-msg"]');
        setTimeout(function(){ try { pw.focus(); } catch (e){} }, 60);
        var done = function(){ v.remove(); };
        v.querySelector('[data-role="reauth-cancel"]').addEventListener('click', function(){ done(); reject(new Error('Confirmation d’identité annulée : rien n’a été fait.')); });
        f.addEventListener('submit', function(ev){
          ev.preventDefault(); var btn = f.querySelector('[type="submit"]'); btn.disabled = true; m.hidden = true;
          c.auth.signInWithPassword({ email: email, password: pw.value }).then(function(r){
            pw.value = '';
            if (r && r.error){ btn.disabled = false; m.hidden = false; m.textContent = 'Mot de passe incorrect.'; return; }
            done(); resolve();
          }, function(){ btn.disabled = false; m.hidden = false; m.textContent = 'Connexion impossible. Réessayez.'; });
        });
      }, function(){ reject(new Error('Votre session a expiré : reconnectez-vous.')); });
    });
  }
  function ttsOn(){ if (!window.speechSynthesis || !window.SpeechSynthesisUtterance) return false; try { return localStorage.getItem(TTS_KEY) !== '0'; } catch (e){ return true; } }
  function stopVoice(){ try { if (window.speechSynthesis) window.speechSynthesis.cancel(); } catch (e){} state.speaking = false; updVoice(); }
  // Fin d'une réponse parlée : en conversation, EVA rouvre le micro pour la suite.
  function spoke(){
    if (!state.speaking) return; state.speaking = false; updVoice();
    if (state.convo && !hf.on && root && !root.hidden && !state.listening) setTimeout(function(){ if (state.convo && !state.speaking && !state.listening) startRec(true); }, 350);
  }
  function speak(text){
    if (!state.voice || !text) return;
    if (!ttsOn()){ if (state.convo) state.convo = false, updVoice(); return; }
    try {
      var u = new SpeechSynthesisUtterance(text); u.lang = 'fr-FR';
      state.speaking = true; updVoice();
      var safety = setTimeout(spoke, Math.max(3000, String(text).length * 95));
      u.onend = u.onerror = function(){ clearTimeout(safety); spoke(); };
      // Mains libres : l'écoute est suspendue pendant qu'EVA parle (elle ne s'entend pas elle-même).
      if (hf.on){
        hf.speaking = true; if (hf.rec) try { hf.rec.abort(); } catch (e){}
        // Filet de sécurité si la synthèse vocale ne signale jamais sa fin.
        var back = function(){ if (!hf.speaking) return; hf.speaking = false; hfRestart(); };
        var prev = u.onend; u.onend = u.onerror = function(){ prev(); back(); }; setTimeout(back, Math.max(2500, String(text).length * 90));
      }
      window.speechSynthesis.cancel(); window.speechSynthesis.speak(u);
    } catch (e){}
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
        '<div class="eva-voice" id="evaVoice" hidden role="status" aria-live="polite"><span class="eva-voice-dot" aria-hidden="true"></span><span class="eva-voice-t" id="evaVoiceT"></span>' +
          '<button type="button" class="eva-btn sm ghost" data-act="stop-voice" id="evaStopVoice" hidden>Arrêter la voix</button>' +
          '<button type="button" class="eva-btn sm ghost" data-act="end-convo" id="evaEndConvo" hidden>Terminer</button></div>' +
        '<div class="eva-hf" id="evaHf" hidden></div>' +
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
  function openProposal(id){
    return rpc('eva_proposal_get', { p_id: id }).then(function(pr){
      if (!pr){ addCard(errorCard('Proposition introuvable.')); return; }
      addCard(proposalCard(pr));
      var s = pr.status === 'PENDING' ? 'Action préparée par Siri : vérifiez puis confirmez.' : 'Cette proposition a déjà été traitée.';
      hintEl.textContent = s;
    }, function(e){ addCard(errorCard(errText(e))); });
  }
  function open(prefill){
    if (!root) build();
    lastFocus = document.activeElement;
    root.hidden = false;
    document.documentElement.style.overflow = 'hidden';
    requestAnimationFrame(function(){ root.classList.add('is-open'); });
    setTab('today');
    loadToday();
    hfBar();
    if (prefill && typeof prefill === 'object' && prefill.proposal){ openProposal(prefill.proposal); prefill = null; }
    if (typeof prefill === 'string' && prefill){ input.value = prefill.slice(0, 300); hintEl.textContent = 'Demande reçue de Siri : relisez-la puis envoyez-la.'; }
    setTimeout(function(){ try { input.focus({ preventScroll: true }); } catch (e){} }, 120);
  }
  function close(){
    if (!root || root.hidden) return;
    endConvo(''); hfStop('');
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
    if (k === 'settings') hfStop('Mains libres arrêté.');
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
    if (p.intent === 'greeting'){ var hr = new Date().getHours(), g = (hr >= 18 || hr < 5 ? 'Bonsoir' : 'Bonjour') + ' ! Que puis-je faire pour vous aujourd’hui ?'; addCard(card(null, p.text, g, '')); speak(g); return; }
    if (p.intent === 'thanks'){ var th = 'Avec plaisir. Autre chose ?'; addCard(card(null, p.text, th, '')); speak(th); return; }
    if (p.intent === 'bye'){ var by = 'À bientôt !'; state.convo = false; addCard(card(null, p.text, by, '')); speak(by); updVoice(); return; }
    if (p.intent === 'details') return details(p);
    if (p.intent === 'yes'){ if (state.offer && state.last){ state.offer = false; return details({ text: p.text, args: { index: null } }); } var ys = 'D’accord. Que souhaitez-vous savoir ?'; addCard(card(null, p.text, ys, '')); speak(ys); return; }
    if (p.intent === 'unknown'){
      addCard('<div class="eva-card"><div class="eva-card-head"><span class="eva-agent">EVA</span><span class="eva-q">« ' + esc(p.text) + ' »</span></div>' +
        '<p class="eva-sum">Je n’ai pas compris cette demande.</p><p class="eva-note">Je ne réponds qu’à partir de vos données réelles. Essayez par exemple :</p>' +
        '<div class="eva-actions">' + I.SUGGESTIONS.slice(0, 4).map(function(s){ return '<button type="button" class="eva-btn sm ghost" data-act="run" data-cmd="' + esc(s) + '">' + esc(s) + '</button>'; }).join('') + '</div></div>');
      speak('Je n’ai pas compris cette demande.');
      return;
    }
    if (p.intent === 'not_yet') return notYet(p);
    if (p.intent === 'dev_request') return devRequestCard(p);
    if (p.intent === 'bulk_refused'){
      var sb1 = 'Je ne fais jamais d’action groupée.';
      addCard(card(null, p.text, sb1, '<p class="eva-note">Envoyer, annuler, modifier ou supprimer plusieurs éléments d’un coup est volontairement impossible avec EVA. Traitez-les un par un : chaque action vous est montrée et vous la confirmez.</p>'));
      speak(sb1); return;
    }
    if (p.intent === 'delete_refused'){
      var sd1 = 'EVA ne supprime aucune donnée.';
      addCard(card(null, p.text, sd1, '<p class="eva-note">Clients, rendez-vous, devis et factures sont conservés. Pour un rendez-vous, dites « annule le rendez-vous de … » : il passe en « Annulé » et reste dans l’historique. Pour une fiche client, utilisez la fusion de doublons dans la rubrique Clients.</p>'));
      speak(sd1); return;
    }
    if (p.intent === 'work_hours') return workHours(p);
    p = withCtx(p);
    var holder = addCard('<div class="eva-card"><div class="eva-card-head"><span class="eva-agent">EVA</span><span class="eva-q">« ' + esc(p.text) + ' »</span></div><p class="eva-empty">Je consulte vos données…</p></div>');
    if (p.intent === 'invoice_last') return invoiceLast(p, holder);
    if (p.intent === 'move_booking' && p.args.to_date && (p.args.client || p.args.client_id)) return runFlow({ intent: 'move_to', args: p.args, text: p.text }, holder);
    if (p.intent === 'move_booking') return moveBooking(p, holder);
    if (FLOW[p.intent]) return runFlow(p, holder);
    if (p.ctxMissing){ var sc = 'De quel client parlez-vous ? Ouvrez d’abord sa fiche, par exemple « fiche de Monsieur Martin ».'; holder.outerHTML = card('clients', p.text, sc, ''); speak(sc); return; }
    if (p.intent === 'quote_estimate' && !p.args.service) return askService(p, holder);
    if (QUERY[p.intent]) return rpc('eva_query', { p_intent: p.intent, p_args: p.args, p_command: p.text }).then(function(r){
      remember(p, r); var out = renderQuery(p, r); holder.outerHTML = out.html; speak(out.say);
    }, function(e){ holder.outerHTML = errorCard(errText(e), p.text); speak(errText(e)); });
    return rpc('eva_run', { p_intent: p.intent, p_args: p.args, p_command: p.text }).then(function(r){
      remember(p, r); var out = render(p, r);
      holder.outerHTML = out.html;
      speak(out.say);
    }, function(e){ holder.outerHTML = errorCard(errText(e), p.text); speak(errText(e)); });
  }
  // ------------------------------------------------ suite de conversation
  // « Donne-moi les détails », « et le premier ? » : portent sur la dernière réponse
  // (données déjà reçues du serveur, rien n'est inventé ni relu ailleurs).
  function remember(p, r){ state.offer = false; state.last = { intent: p.intent, data: (r && r.data) || {}, at: Date.now() }; }
  function hm(t){ var m = /^(\d{1,2}):(\d{2})/.exec(String(t || '')); return m ? Number(m[1]) + ' h' + (m[2] !== '00' ? ' ' + m[2] : '') : ''; }
  function detailsOf(L, idx){
    var d = L.data || {}, items, fmt, agent = null, noun;
    switch (L.intent){
      case 'agenda': items = d.interventions || []; agent = 'planning'; noun = 'intervention';
        fmt = function(x){ return 'À ' + hm(x.start) + ' : ' + x.service + ' chez ' + x.client + (x.address ? ', ' + x.address : '') + (x.phone ? ', téléphone ' + x.phone : '') + (x.status === 'PENDING' ? ', à confirmer' : '') + '.'; }; break;
      case 'agenda_range': items = [].concat.apply([], (d.days || []).map(function(day){ return day.items || []; })); agent = 'planning'; noun = 'rendez-vous';
        fmt = function(x){ return dayLabel(x.date) + ' à ' + hm(x.start) + ' : ' + x.service + ', ' + x.client + (x.status === 'PENDING' ? ', à confirmer' : '') + '.'; }; break;
      case 'brief': return d.agenda ? detailsOf({ intent: 'agenda', data: d.agenda }, idx) : null;
      case 'quotes_pending': items = (d.drafts || []).concat(d.sent || []); agent = 'devis'; noun = 'devis';
        fmt = function(x){ return (x.title || x.reference || 'Devis') + ', ' + x.client + ', ' + eur(x.total_cents) + (x.sent_days != null ? ', envoyé il y a ' + x.sent_days + ' jour' + (x.sent_days > 1 ? 's' : '') : ', brouillon') + '.'; }; break;
      case 'awaiting': items = d.booking_requests || []; agent = 'planning'; noun = 'demande';
        fmt = function(x){ return x.client + ' : ' + x.service + ', ' + dayLabel(x.date) + ' à ' + hm(x.start) + '.'; }; break;
      case 'find_client': items = d.clients || []; agent = 'clients'; noun = 'client';
        fmt = function(x){ return x.name + (x.city ? ', ' + x.city : '') + (x.phone ? ', téléphone ' + x.phone : '') + (x.email ? ', ' + x.email : '') + '.'; }; break;
      case 'maintenance_due': items = d.items || []; agent = 'planning'; noun = 'entretien';
        fmt = function(x){ return x.client + ' : ' + (x.equipment || x.type || 'équipement') + (x.overdue ? ', en retard' : ', à prévoir avant le ' + fdate(x.next_due)) + '.'; }; break;
      case 'attention': items = d.items || []; noun = 'point';
        fmt = function(x){ return x.message; }; break;
      case 'free_slots': items = d.slots || []; agent = 'planning'; noun = 'créneau';
        fmt = function(x){ return dayLabel(x.date) + ', de ' + hm(x.start) + ' à ' + hm(x.end) + '.'; }; break;
      case 'invoices_todo': agent = 'factures'; noun = 'élément';
        items = (d.completed_without_invoice || []).map(function(x){ return Object.assign({ k: 'b' }, x); }).concat((d.unpaid || []).map(function(x){ return Object.assign({ k: 'u' }, x); }));
        fmt = function(x){ return x.k === 'b' ? 'Intervention ' + x.reference + ' terminée chez ' + x.client + ', sans facture.' : 'Facture ' + x.reference + ', ' + x.client + ', ' + eur((x.total_cents || 0) - (x.paid_cents || 0)) + ' restant dus.'; }; break;
      default: return null;
    }
    var pl = noun === 'créneau' ? 'créneaux' : /[sx]$/.test(noun) ? noun : noun + 's';
    if (!items.length) return { agent: agent, sum: 'Il n’y a aucun ' + noun + ' à détailler.' };
    if (idx != null){
      var k = idx < 0 ? items.length + idx : idx, x = items[k];
      if (!x) return { agent: agent, sum: 'Il n’y en a que ' + items.length + '.' };
      if (x.client_id) setCtx({ client_id: x.client_id, name: x.client || x.name });
      return { agent: agent, sum: fmt(x) };
    }
    var lines = items.slice(0, 8).map(fmt);
    return { agent: agent, sum: items.length + ' ' + (items.length > 1 ? pl : noun) + (items.length > 8 ? ', voici les 8 premiers' : '') + ' :',
      body: '<ul class="eva-list">' + lines.map(function(l){ return '<li class="eva-item"><div class="eva-main"><span>' + esc(l) + '</span></div></li>'; }).join('') + '</ul>', say: lines.join(' ') };
  }
  function details(p){
    var L = state.last, out = L && Date.now() - L.at < 15 * 60000 ? detailsOf(L, p.args && p.args.index) : null;
    if (!out){ var s0 = 'De quoi souhaitez-vous le détail ? Posez d’abord une question, par exemple « mes rendez-vous de demain ».'; addCard(card(null, p.text, s0, '')); speak(s0); return; }
    addCard(card(out.agent, p.text, out.sum, out.body || '')); speak(out.say ? out.sum + ' ' + out.say : out.sum);
  }
  // Barre d'état vocale : écoute, réflexion, parole ; arrêt de la voix et fin de conversation.
  function updVoice(){
    if (!root) return;
    var v = root.querySelector('#evaVoice'); if (!v) return;
    var mode = state.listening ? 'listening' : state.pending > 0 ? 'thinking' : state.speaking ? 'speaking' : state.convo ? 'waiting' : '';
    root.classList.toggle('is-listening', mode === 'listening'); root.classList.toggle('is-thinking', mode === 'thinking'); root.classList.toggle('is-speaking', mode === 'speaking');
    v.hidden = !mode; v.setAttribute('data-mode', mode);
    root.querySelector('#evaVoiceT').textContent = { listening: 'EVA vous écoute…', thinking: 'EVA réfléchit…', speaking: 'EVA vous répond…', waiting: 'Conversation en cours' }[mode] || '';
    root.querySelector('#evaStopVoice').hidden = mode !== 'speaking';
    root.querySelector('#evaEndConvo').hidden = !state.convo;
    var vb = root.querySelector('#evaListen [data-act="end-convo"]'); if (vb) vb.hidden = !state.convo;
  }
  function endConvo(msg){ state.convo = false; stopMic(); stopVoice(); updVoice(); if (msg && hintEl) hintEl.textContent = msg; }
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
    var say = day + ', vous avez ' + n + ' intervention' + (n > 1 ? 's prévues' : ' prévue') + '. ' + (n > 1 ? 'La première à ' : 'À ') + hm(first.start) + ', chez ' + first.client + '.' + (n > 1 ? ' Voulez-vous les détails ?' : '');
    state.offer = n > 1;
    return { html: card('planning', p.text, sum, '<p class="eva-note" style="margin:-6px 0 10px">' + esc(full) + '</p>' + agendaItems(d) + agendaExtras(d)), say: say };
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
    if (c.length === 1) setCtx(c[0]);
    var sum = d.last ? (c.length ? 'Votre dernier client : ' + (c[0].name || 'sans nom') + '.' : 'Aucune fiche client pour le moment.')
      : c.length ? c.length + ' client' + (c.length > 1 ? 's' : '') + ' trouvé' + (c.length > 1 ? 's' : '') + '.' : 'Aucun client ne correspond à « ' + (d.query || '') + ' » dans votre base.';
    var body = c.length ? '<ul class="eva-list">' + c.map(function(x){
      return '<li class="eva-item"><div class="eva-main"><b>' + esc(x.name || 'Sans nom') + '</b>' + (x.city ? '<span>' + esc(x.city) + '</span>' : '') +
        (x.phone ? '<a href="tel:' + esc(String(x.phone).replace(/\s/g, '')) + '">' + esc(x.phone) + '</a>' : '') + (x.email ? '<a href="mailto:' + esc(x.email) + '">' + esc(x.email) + '</a>' : '') +
        '<div class="eva-actions">' + runBtn('Ouvrir la fiche', 'client_detail', { client_id: x.client_id }, 'Fiche de ' + (x.name || 'client')) + '</div></div></li>';
    }).join('') + '</ul>' : '';
    return { html: card(null, p.text, sum, body), say: sum };
  }
  function renderEstimate(p, d){
    var clients = d.clients || [], matches = d.matches || [], miss = d.missing || [];
    var client = clients.length === 1 ? clients[0] : null;
    if (client) setCtx(client);
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

  // ------------------------------------------------ phase 2 : lectures
  var FLOW = { booking_confirm: 1, move_to: 1, client_create: 1, client_update: 1, booking_create: 1, booking_cancel: 1, service_create: 1, quote_update: 1, quote_send: 1, report: 1, referrer_admin: 1, wallet_adjust: 1 };
  var QUERY = { agenda_range: 1, stats: 1, catalog: 1, invoices_list: 1, client_detail: 1, loyalty: 1, maintenance_due: 1, referrals: 1 };
  var ISTATUS = { DRAFT: ['Brouillon', 'info'], ISSUED: ['Émise', 'wait'], PARTIALLY_PAID: ['Partiellement réglée', 'wait'], PAID: ['Réglée', 'ok'], CANCELLED: ['Annulée', 'no'], CREDITED: ['Avoir', 'no'] };
  var BSTATUS = { PENDING: ['À confirmer', 'wait'], CONFIRMED: ['Confirmé', 'ok'], IN_PROGRESS: ['En cours', 'info'], COMPLETED: ['Terminé', 'ok'], CANCELLED: ['Annulé', 'no'], NO_SHOW: ['Absent', 'no'] };
  var EQUIP = { chaudiere_gaz: 'Chaudière gaz', chaudiere_fioul: 'Chaudière fioul', pompe_a_chaleur: 'Pompe à chaleur', climatisation: 'Climatisation', chauffe_eau: 'Chauffe-eau', ballon_thermo: 'Ballon thermodynamique' };
  var METHOD = { virement: 'Virement', cheque: 'Chèque', especes: 'Espèces', carte: 'Carte bancaire', autre: 'Autre' };
  function fdate(d){ var x = parseIso(d); return x ? x.toLocaleDateString('fr-FR') : '—'; }
  function pill(map, k){ var s = map[k] || [k || '—', 'info']; return '<span class="eva-pill ' + s[1] + '">' + esc(s[0]) + '</span>'; }
  function tel(p){ return p ? '<a href="tel:' + esc(String(p).replace(/\s/g, '')) + '">' + esc(p) + '</a>' : ''; }
  function setCtx(c){ if (c && c.client_id) state.ctx = { client_id: c.client_id, name: c.name || '' }; }
  function actBtn(label, act, o, cls){ return '<button type="button" class="eva-btn sm ' + (cls || 'ghost') + '" data-act="' + act + '" data-k="' + reg(o) + '">' + esc(label) + '</button>'; }
  function runBtn(label, intent, args, text){ return actBtn(label, 'rerun', { intent: intent, args: args, text: text || label }); }
  // « ce client » : remplacé par le client de la conversation, sinon EVA demande lequel.
  function withCtx(p){
    if (!p.args || p.args.client !== '@ctx') return p;
    var a = Object.assign({}, p.args); delete a.client;
    if (state.ctx) a.client_id = state.ctx.client_id;
    return Object.assign({}, p, { args: a, ctxMissing: !state.ctx });
  }

  function renderQuery(p, r){
    var d = r.data || {};
    switch (p.intent){
      case 'agenda_range': return renderRange(p, d);
      case 'stats': return renderStats(p, d);
      case 'catalog': return renderCatalog(p, d);
      case 'invoices_list': return renderInvoicesList(p, d);
      case 'client_detail': return renderDetail(p, d);
      case 'loyalty': return renderLoyalty(p, d);
      case 'maintenance_due': return renderMaintenance(p, d);
      case 'referrals': return renderReferrals(p, d);
    }
    return { html: errorCard('Réponse inattendue.', p.text), say: '' };
  }
  function noClient(p, d, intent, extra){
    var cl = d.clients || [];
    if (cl.length > 1) return { html: card('clients', p.text, 'Plusieurs clients correspondent.', clientChoice(p, cl, intent, extra)), say: 'Plusieurs clients correspondent. Lequel ?' };
    var s = 'Aucun client ne correspond à « ' + (p.args.client || p.args.query || '') + ' » dans votre base.';
    return { html: card('clients', p.text, s, '<div class="eva-actions">' + runBtn('Créer cette fiche client', 'client_create', nameArgs(p.args.client), 'Nouveau client') + '</div>'), say: s };
  }
  function nameArgs(n){
    var w = String(n || '').replace(/^(monsieur|madame|mademoiselle|mme|m\.|mr)\s+/i, '').trim().split(/\s+/).filter(Boolean);
    return { first_name: w.length > 1 ? w[0] : '', last_name: w.length > 1 ? w.slice(1).join(' ') : (w[0] || ''), phone: '', email: '' };
  }
  function bookingRow(x, extra){
    return '<li class="eva-item"><div class="eva-time">' + esc(x.start) + '<small>' + esc(x.end) + '</small></div><div class="eva-main"><b>' + esc(x.service) + '</b><span>' + esc(x.client) + ' · ' + esc(x.reference) + '</span>' + (extra || '') + '</div>' + pill(BSTATUS, x.status) + '</li>';
  }
  function renderRange(p, d){
    var n = d.count || 0, by = d.by_status || {}, canc = (by.CANCELLED || 0) + (by.NO_SHOW || 0);
    var sum = periodLabel(d).replace(/^./, function(c){ return c.toUpperCase(); }) + ' : ' + (n ? n + ' rendez-vous' : 'aucun rendez-vous') + '.';
    var parts = [['PENDING', 'à confirmer'], ['CONFIRMED', 'confirmé(s)'], ['IN_PROGRESS', 'en cours'], ['COMPLETED', 'terminé(s)']].filter(function(k){ return by[k[0]]; }).map(function(k){ return by[k[0]] + ' ' + k[1]; });
    var b = (parts.length ? '<p class="eva-note" style="margin-top:-6px">' + esc(parts.join(' · ')) + (canc ? ' · ' + canc + ' annulé(s) ou absent(s) non comptés' : '') + '.</p>' : (canc ? '<p class="eva-note">' + canc + ' rendez-vous annulé(s) sur la période, non comptés.</p>' : ''));
    b += (d.days || []).map(function(day){ return '<p class="eva-h">' + esc(dayLabel(day.date)) + '</p><ul class="eva-list">' + day.items.map(function(x){ return bookingRow(x); }).join('') + '</ul>'; }).join('');
    return { html: card('planning', p.text, sum, b), say: sum };
  }
  function renderStats(p, d){
    var rows = [['Demandes reçues', d.requests_received], ['Rendez-vous confirmés', d.confirmed], ['Interventions terminées', d.completed], ['Annulés par le client', d.cancelled_client],
      ['Annulés par vous', d.cancelled_admin], ['Demandes refusées', d.refused], ['Clients absents', d.no_show]];
    var sum = 'Statistiques ' + periodLabel(d) + ' : ' + (d.requests_received || 0) + ' demande(s) reçue(s), ' + (d.confirmed || 0) + ' rendez-vous confirmé(s), ' + (d.completed || 0) + ' terminé(s).';
    var b = '<ul class="eva-list">' + rows.map(function(r){ return '<li class="eva-item"><div class="eva-main"><b>' + esc(r[0]) + '</b></div><span class="eva-pill info">' + (r[1] || 0) + '</span></li>'; }).join('') +
      '<li class="eva-item"><div class="eva-main"><b>Montant des interventions terminées</b><span>' + (d.revenue_countable || 0) + ' intervention(s) avec un montant enregistré</span></div><span class="eva-pill ok">' + eur(d.revenue_cents || 0) + '</span></li></ul>' +
      '<p class="eva-note">Montants des rendez-vous terminés, pas des factures : pour le facturé et l’encaissé, demandez « combien j’ai facturé ce mois ».</p>';
    return { html: card('planning', p.text, sum, b), say: sum };
  }
  function priceText(x){ return x.mode === 'QUOTE' ? 'Sur devis' : x.price_cents == null ? 'Prix non renseigné' : (x.mode === 'FROM' ? 'À partir de ' : '') + eur(x.price_cents); }
  function renderCatalog(p, d){
    var it = d.items || [];
    var sum = it.length ? (it.length === 1 ? it[0].label + ' : ' + priceText(it[0]) + (it[0].duration_minutes ? ', ' + it[0].duration_minutes + ' min' : '') + '.' : it.length + ' prestation' + (it.length > 1 ? 's' : '') + ' dans votre catalogue' + (d.query ? ' pour « ' + d.query + ' »' : '') + '.')
      : 'Aucune prestation de votre catalogue ne correspond à « ' + (d.query || '') + ' ».';
    var cats = {}; it.forEach(function(x){ (cats[x.category || 'autre'] = cats[x.category || 'autre'] || []).push(x); });
    var b = Object.keys(cats).map(function(c){ return '<p class="eva-h">' + esc(c.charAt(0).toUpperCase() + c.slice(1)) + '</p><ul class="eva-list">' + cats[c].map(function(x){
      return '<li class="eva-item"><div class="eva-main"><b>' + esc(x.label) + '</b><span>' + (x.duration_minutes ? x.duration_minutes + ' min' : 'Durée non renseignée') + (x.active ? '' : ' · masquée') + '</span></div><span class="eva-pill ' + (x.mode === 'FIXED' && x.price_cents != null ? 'ok' : 'info') + '">' + esc(priceText(x)) + '</span></li>';
    }).join('') + '</ul>'; }).join('');
    b += '<p class="eva-note">Tarifs enregistrés dans votre catalogue, sans frais de déplacement.</p><div class="eva-actions">' + runBtn('Ajouter une prestation', 'service_create', { name: '' }, 'Ajouter une prestation') + '</div>';
    return { html: card('devis', p.text, sum, b), say: sum };
  }
  function renderInvoicesList(p, d){
    if ((p.args.client || p.args.client_id) && (d.clients || []).length !== 1) return noClient(p, d, 'invoices_list', { from: p.args.from, to: p.args.to });
    var inv = d.invoices || [], pay = d.payments || [], who = (d.clients || [])[0];
    if (who) setCtx(who);
    var paid = pay.reduce(function(s, x){ return s + (x.amount_cents || 0); }, 0);
    if (p.args.last){
      var l0 = inv[0], sl = l0 ? 'Dernière facture' + (who ? ' de ' + who.name : '') + ' : ' + (l0.reference || 'brouillon') + ', ' + l0.client + ', ' + eur(l0.total_cents) + ' (' + (ISTATUS[l0.status] || [l0.status])[0].toLowerCase() + ').' : 'Aucune facture' + (who ? ' pour ' + who.name : '') + '.';
      return { html: card('factures', p.text, sl, l0 ? '<ul class="eva-list"><li class="eva-item"><div class="eva-main"><b>' + esc(l0.reference || 'Brouillon') + '</b><span>' + esc(l0.client) + (l0.issued_at ? ' · émise le ' + esc(new Date(l0.issued_at).toLocaleDateString('fr-FR')) : '') + ' · réglé ' + eur(l0.paid_cents) + ' sur ' + eur(l0.total_cents) + '</span></div>' + pill(ISTATUS, l0.status) + '</li></ul><div class="eva-actions"><button type="button" class="eva-btn sm ghost" data-act="goto" data-page="invoices">Ouvrir la rubrique Factures</button></div>' : ''), say: sl };
    }
    var sum = (who ? who.name + ' : ' : '') + inv.length + ' facture' + (inv.length > 1 ? 's' : '') + ', ' + pay.length + ' paiement' + (pay.length > 1 ? 's' : '') + ' enregistré' + (pay.length > 1 ? 's' : '') + (pay.length ? ' (' + eur(paid) + ')' : '') + (p.args.from ? ' ' + periodLabel(p.args) : '') + '.';
    var b = '';
    if (inv.length) b += '<p class="eva-h">Factures</p><ul class="eva-list">' + inv.map(function(x){ return '<li class="eva-item"><div class="eva-main"><b>' + esc(x.reference || 'Brouillon') + '</b><span>' + esc(x.client) + (x.issued_at ? ' · émise le ' + esc(new Date(x.issued_at).toLocaleDateString('fr-FR')) : '') + ' · réglé ' + eur(x.paid_cents) + ' sur ' + eur(x.total_cents) + '</span></div>' + pill(ISTATUS, x.status) + '</li>'; }).join('') + '</ul>';
    if (pay.length) b += '<p class="eva-h">Paiements reçus</p><ul class="eva-list">' + pay.map(function(x){ return '<li class="eva-item"><div class="eva-time">' + esc((parseIso(x.paid_on) || new Date()).toLocaleDateString('fr-FR', { day: '2-digit', month: '2-digit' })) + '</div><div class="eva-main"><b>' + esc(x.client) + '</b><span>' + esc(x.invoice || '') + ' · ' + esc(METHOD[x.method] || x.method || '') + '</span></div><span class="eva-pill ok">' + eur(x.amount_cents) + '</span></li>'; }).join('') + '</ul>';
    b += '<div class="eva-actions"><button type="button" class="eva-btn sm ghost" data-act="goto" data-page="invoices">Ouvrir la rubrique Factures</button></div>';
    return { html: card('factures', p.text, sum, b), say: sum };
  }
  function equipName(e){ return (EQUIP[e.type] || e.type || 'Équipement') + ((e.brand || e.model) ? ' ' + [e.brand, e.model].filter(Boolean).join(' ') : ''); }
  function renderDetail(p, d){
    if (!d.client) return noClient(p, d, 'client_detail', { focus: p.args.focus });
    var c = d.client, iv = d.interventions || [], bk = d.bookings || [], eq = d.equipment || [], qs = d.quotes || [], fs = d.invoices || [];
    setCtx(c);
    var today = I.iso(new Date()), next = bk.filter(function(x){ return x.date >= today && (x.status === 'PENDING' || x.status === 'CONFIRMED'); }).slice(-1)[0];
    var last = iv[0], lastDone = bk.filter(function(x){ return x.status === 'COMPLETED'; })[0], sum;
    if (p.args.focus === 'interventions') sum = last ? 'Dernière intervention chez ' + c.name + ' : ' + last.service + ' le ' + fdate(last.date) + (last.equipment ? ' (' + last.equipment + ')' : '') + '.'
      : (lastDone ? 'Dernière intervention chez ' + c.name + ' : ' + lastDone.service + ' le ' + fdate(lastDone.date) + ' (sans fiche d’intervention).' : 'Aucune intervention enregistrée chez ' + c.name + '.');
    else if (p.args.focus === 'equipment') sum = eq.length ? c.name + ' : ' + eq.length + ' équipement' + (eq.length > 1 ? 's' : '') + ' enregistré' + (eq.length > 1 ? 's' : '') + '.' : 'Aucun équipement enregistré chez ' + c.name + '.';
    else sum = 'Fiche de ' + c.name + ' : ' + bk.length + ' rendez-vous, ' + qs.length + ' devis, ' + fs.length + ' facture' + (fs.length > 1 ? 's' : '') + '.' + (next ? ' Prochain rendez-vous le ' + fdate(next.date) + ' à ' + next.start + '.' : '');
    var b = '<ul class="eva-list"><li class="eva-item"><div class="eva-main"><b>' + esc(c.name) + (c.type === 'professionnel' ? ' · professionnel' : '') + '</b>' +
      (c.address || c.city ? '<span>' + esc([c.address, [c.postal_code, c.city].filter(Boolean).join(' ')].filter(Boolean).join(', ')) + '</span>' : '') + tel(c.phone) +
      (c.email ? '<a href="mailto:' + esc(c.email) + '">' + esc(c.email) + '</a>' : '') + (c.notes ? '<span>Notes : ' + esc(c.notes) + '</span>' : '') +
      '<span>' + (c.has_account ? 'Compte client actif' : 'Sans compte client') + (d.wallet_cents ? ' · crédit fidélité ' + eur(d.wallet_cents) : '') + (d.referral ? ' · parrain (code ' + esc(d.referral.code) + ', ' + esc(d.referral.status === 'active' ? 'actif' : d.referral.status) + ')' : '') + '</span></div></li></ul>';
    if (iv.length) b += '<p class="eva-h">Interventions</p><ul class="eva-list">' + iv.slice(0, 6).map(function(x){
      return '<li class="eva-item"><div class="eva-time">' + esc((parseIso(x.date) || new Date(x.date)).toLocaleDateString('fr-FR', { day: '2-digit', month: '2-digit', year: '2-digit' })) + '</div><div class="eva-main"><b>' + esc(x.service) + '</b><span>' + esc(x.booking || '') + (x.equipment ? ' · ' + esc(x.equipment) : '') + '</span>' +
        (x.observations ? '<span>Observations : ' + esc(x.observations) + '</span>' : '') + (x.recommendations ? '<span>Recommandations : ' + esc(x.recommendations) + '</span>' : '') + '</div>' +
        '<span class="eva-pill ' + (x.report_status === 'FINALIZED' ? 'ok' : 'info') + '">' + (x.report_status === 'FINALIZED' ? 'CR validé' : 'CR brouillon') + '</span></li>';
    }).join('') + '</ul>';
    if (eq.length) b += '<p class="eva-h">Équipements</p><ul class="eva-list">' + eq.map(function(e){
      var od = e.next_due && e.next_due < today;
      return '<li class="eva-item"><div class="eva-main"><b>' + esc(equipName(e)) + '</b><span>' + (e.location ? esc(e.location) + ' · ' : '') + 'Dernier entretien : ' + (e.last_service ? fdate(e.last_service) : 'non renseigné') + '</span></div>' +
        (e.next_due ? '<span class="eva-pill ' + (od ? 'no' : 'wait') + '">' + (od ? 'Échu le ' : 'Avant le ') + esc(fdate(e.next_due)) + '</span>' : '') + '</li>';
    }).join('') + '</ul>';
    if (bk.length) b += '<p class="eva-h">Rendez-vous</p><ul class="eva-list">' + bk.slice(0, 6).map(function(x){ return '<li class="eva-item"><div class="eva-time">' + esc((parseIso(x.date) || new Date()).toLocaleDateString('fr-FR', { day: '2-digit', month: '2-digit', year: '2-digit' })) + '<small>' + esc(x.start) + '</small></div><div class="eva-main"><b>' + esc(x.service) + '</b><span>' + esc(x.reference) + '</span></div>' + pill(BSTATUS, x.status) + '</li>'; }).join('') + '</ul>';
    if (qs.length) b += '<p class="eva-h">Devis</p><ul class="eva-list">' + qs.slice(0, 5).map(function(x){ return '<li class="eva-item"><div class="eva-main"><b>' + esc(x.title || 'Devis') + '</b><span>' + esc(x.reference || '') + '</span></div><span class="eva-pill ' + (QSTATUS[x.status] || ['', 'info'])[1] + '">' + esc((QSTATUS[x.status] || [x.status])[0]) + ' · ' + eur(x.total_cents) + '</span></li>'; }).join('') + '</ul>';
    if (fs.length) b += '<p class="eva-h">Factures</p><ul class="eva-list">' + fs.slice(0, 5).map(function(x){ return '<li class="eva-item"><div class="eva-main"><b>' + esc(x.reference || 'Brouillon') + '</b></div>' + pill(ISTATUS, x.status) + '<span class="eva-pill info">' + eur(x.total_cents) + '</span></li>'; }).join('') + '</ul>';
    var a = { client_id: c.client_id };
    b += '<p class="eva-note">« ce client » désigne maintenant ' + esc(c.name) + '.</p><div class="eva-actions">' +
      runBtn('Nouveau rendez-vous', 'booking_create', a, 'Nouveau rendez-vous — ' + c.name) + runBtn('Préparer un devis', 'quote_estimate', Object.assign({ service: '' }, a), 'Devis — ' + c.name) +
      runBtn('Modifier la fiche', 'client_update', a, 'Modifier la fiche — ' + c.name) + (bk.some(function(x){ return x.status === 'COMPLETED' || x.status === 'IN_PROGRESS'; }) ? runBtn('Compte rendu', 'report', a, 'Compte rendu — ' + c.name) : '') +
      runBtn('Fidélité', 'loyalty', a, 'Fidélité — ' + c.name) + '</div>';
    return { html: card('clients', p.text, sum, b), say: sum };
  }
  var WTYPE = { REFERRAL_REFERRER: 'Récompense de parrainage', REFERRAL_REFEREE: 'Bienvenue (filleul)', ADJUSTMENT: 'Ajustement', EXPIRED: 'Expiration', BOOKING_CANCELLED: 'Rendez-vous annulé' };
  function renderLoyalty(p, d){
    if (d.balance_cents == null) return noClient(p, d, 'loyalty');
    var who = (d.clients || [])[0] || { name: 'Ce client', client_id: d.client_id }; setCtx(who);
    var t = d.transactions || [], sum = who.name + ' : crédit fidélité de ' + eur(d.balance_cents) + '.';
    var b = t.length ? '<ul class="eva-list">' + t.map(function(x){ return '<li class="eva-item"><div class="eva-time">' + esc(new Date(x.at).toLocaleDateString('fr-FR', { day: '2-digit', month: '2-digit', year: '2-digit' })) + '</div><div class="eva-main"><b>' + esc(WTYPE[x.type] || 'Opération') + '</b>' + (x.reason ? '<span>' + esc(x.reason) + '</span>' : '') + '</div><span class="eva-pill ' + (x.amount_cents < 0 ? 'no' : 'ok') + '">' + (x.amount_cents > 0 ? '+' : '') + eur(x.amount_cents) + '</span></li>'; }).join('') + '</ul>' : '<p class="eva-empty">Aucune opération enregistrée.</p>';
    b += '<div class="eva-actions">' + runBtn('Créditer ou débiter', 'wallet_adjust', { client_id: d.client_id, amount: null }, 'Crédit fidélité — ' + who.name) + '</div>';
    return { html: card('fidelite', p.text, sum, b), say: sum };
  }
  function renderMaintenance(p, d){
    var it = d.items || [], od = it.filter(function(x){ return x.overdue; }).length;
    var sum = it.length ? it.length + ' entretien' + (it.length > 1 ? 's' : '') + ' à renouveler' + (od ? ', dont ' + od + ' en retard' : '') + ' (échéance dans les ' + d.days + ' jours ou dépassée).' : 'Aucun entretien à renouveler dans les ' + d.days + ' prochains jours.';
    var b = it.length ? '<ul class="eva-list">' + it.map(function(x){
      return '<li class="eva-item"><div class="eva-main"><b>' + esc(x.client) + '</b><span>' + esc(EQUIP[x.type] && x.equipment === x.type ? EQUIP[x.type] : x.equipment) + (x.city ? ' · ' + esc(x.city) : '') + ' · dernier entretien ' + (x.last_service ? fdate(x.last_service) : 'non renseigné') + '</span>' + tel(x.phone) +
        (x.next_booking ? '<span>Rendez-vous déjà prévu le ' + esc(fdate(x.next_booking)) + '</span>' : '<div class="eva-actions">' + runBtn('Prendre rendez-vous', 'booking_create', { client_id: x.client_id, service: 'entretien' }, 'Rendez-vous d’entretien — ' + x.client) + '</div>') + '</div>' +
        '<span class="eva-pill ' + (x.overdue ? 'no' : 'wait') + '">' + (x.overdue ? 'Échu le ' : 'Avant le ') + esc(fdate(x.next_due)) + '</span></li>';
    }).join('') + '</ul><p class="eva-note">Échéance calculée à partir de la date du dernier entretien enregistrée sur chaque équipement.</p>' : '';
    return { html: card('planning', p.text, sum, b), say: sum };
  }
  function renderReferrals(p, d){
    var r = d.referrers || [], act = r.filter(function(x){ return x.status === 'active'; }).length;
    var sum = r.length ? r.length + ' parrain' + (r.length > 1 ? 's' : '') + (d.query ? ' pour « ' + d.query + ' »' : '') + ', dont ' + act + ' actif' + (act > 1 ? 's' : '') + '.' : 'Aucun parrain' + (d.query ? ' pour « ' + d.query + ' »' : '') + '.';
    var b = r.length ? '<ul class="eva-list">' + r.map(function(x){
      return '<li class="eva-item"><div class="eva-main"><b>' + esc(x.name || 'Sans nom') + '</b><span>Code ' + esc(x.code) + ' · ' + (x.uses || 0) + ' utilisation(s)' + (x.clients != null ? ' · ' + x.clients + ' client(s) parrainé(s)' : '') + '</span><div class="eva-actions">' +
        (x.status === 'active' ? actBtn('Suspendre', 'prop', { kind: 'referrer_status', payload: { client_id: x.client_id, status: 'suspended' }, idem: key() }) : actBtn('Réactiver', 'prop', { kind: 'referrer_status', payload: { client_id: x.client_id, status: 'active' }, idem: key() })) +
        runBtn('Changer le code', 'referrer_admin', { client_id: x.client_id, code: '' }, 'Code de parrainage — ' + (x.name || '')) + '</div></div>' +
        '<span class="eva-pill ' + (x.status === 'active' ? 'ok' : 'no') + '">' + (x.status === 'active' ? 'Actif' : x.status === 'suspended' ? 'Suspendu' : esc(x.status)) + '</span></li>';
    }).join('') + '</ul>' : '';
    b += '<div class="eva-actions"><button type="button" class="eva-btn sm ghost" data-act="goto" data-page="referrals">Ouvrir la rubrique Parrainage</button></div>';
    return { html: card('fidelite', p.text, sum, b), say: sum };
  }

  // -------------------------------------- phase 2 : actions (formulaires)
  // Chaque formulaire prépare une PROPOSITION : rien n'est écrit avant
  // votre confirmation, et le serveur revérifie chaque valeur.
  function field(f){
    var v = f.value == null ? '' : f.value, req = f.required ? ' required aria-required="true"' : '', ph = f.placeholder ? ' placeholder="' + esc(f.placeholder) + '"' : '';
    if (f.type === 'radio') return '<p class="eva-h">' + esc(f.label) + '</p><div class="eva-list">' + f.options.map(function(o, i){
      return '<label class="eva-radio"><input type="radio" name="' + f.group + '" data-f="' + f.name + '" value="' + esc(o[0]) + '"' + (i === 0 ? ' checked' : '') + '><span>' + esc(o[1]) + '</span>' + (o[2] ? '<em>' + esc(o[2]) + '</em>' : '') + '</label>';
    }).join('') + '</div>';
    if (f.type === 'select') return '<label class="eva-field">' + esc(f.label) + '<select data-f="' + f.name + '"' + req + '>' + f.options.map(function(o){ return '<option value="' + esc(o[0]) + '"' + (String(o[0]) === String(v) ? ' selected' : '') + '>' + esc(o[1]) + '</option>'; }).join('') + '</select></label>';
    if (f.type === 'textarea') return '<label class="eva-field">' + esc(f.label) + '<textarea data-f="' + f.name + '" rows="' + (f.rows || 3) + '" maxlength="' + (f.max || 1000) + '"' + req + ph + '>' + esc(v) + '</textarea></label>';
    var type = f.type === 'eur' ? 'number' : (f.type || 'text');
    var extra = f.type === 'eur' ? ' inputmode="decimal" min="0" step="0.01"' : f.type === 'number' ? ' inputmode="numeric" min="' + (f.min || 0) + '" step="' + (f.step || 1) + '"' : f.type === 'tel' ? ' inputmode="tel" autocomplete="off"' : f.type === 'email' ? ' inputmode="email" autocomplete="off"' : f.type === 'time' ? ' step="300"' : '';
    return '<label class="eva-field">' + esc(f.label) + '<input type="' + type + '" data-f="' + f.name + '" value="' + esc(type === 'number' && f.type === 'eur' && v !== '' ? (Number(v) / 100).toFixed(2) : v) + '"' + extra + req + ph + (f.max ? ' maxlength="' + f.max + '"' : '') + '></label>';
  }
  // o = { kind, fields, build(values) → payload, submit, idem, intro, agent }
  function formCard(p, sum, o){
    o.idem = o.idem || key();
    o.fields.forEach(function(f){ if (f.type === 'radio') f.group = 'g' + (++state.seq); });
    return card(o.agent || KIND_AGENT[o.kind], p.text, sum, (o.intro || '') + '<div class="eva-set eva-form">' + o.fields.map(field).join('') +
      '<div class="eva-actions" style="margin-top:4px"><button type="button" class="eva-btn cu" data-act="form" data-k="' + reg(o) + '">' + esc(o.submit || 'Préparer') + '</button></div>' +
      '<p class="eva-msg" data-role="form-msg" hidden></p><p class="eva-note" style="margin:0">Rien n’est enregistré à cette étape : EVA vous montre d’abord ce qui va changer.</p></div>');
  }
  function submitForm(b, o){
    var f = b.closest('.eva-form'), msg = f.querySelector('[data-role="form-msg"]'), v = {}, miss = [];
    o.fields.forEach(function(x){
      var el = x.type === 'radio' ? f.querySelector('input[data-f="' + x.name + '"]:checked') : f.querySelector('[data-f="' + x.name + '"]');
      var val = el ? String(el.value).trim() : '';
      if (x.type === 'eur') val = val === '' ? null : Math.round(Number(val.replace(',', '.')) * 100);
      else if (x.type === 'number') val = val === '' ? null : Number(val);
      if (x.required && (val === '' || val == null || (typeof val === 'number' && isNaN(val)))) miss.push(x.label);
      v[x.name] = val;
    });
    if (miss.length){ msg.hidden = false; msg.className = 'eva-msg no'; msg.textContent = 'À compléter : ' + miss.join(', ') + '.'; return; }
    var payload; try { payload = o.build(v); } catch (e){ msg.hidden = false; msg.className = 'eva-msg no'; msg.textContent = e.message; return; }
    msg.hidden = true;
    return propose(o.kind, payload, o.idem, b, msg);
  }
  // Fiche client complète (pour les actions qui en ont besoin).
  function withClient(p, holder, then){
    if (p.ctxMissing){ var s = 'De quel client parlez-vous ? Ouvrez d’abord sa fiche, par exemple « fiche de Monsieur Martin ».'; holder.outerHTML = card('clients', p.text, s, ''); speak(s); return Promise.resolve(); }
    if (!p.args.client && !p.args.client_id){ var s2 = 'Pour quel client ? Précisez son nom, par exemple « … pour Monsieur Martin ».'; holder.outerHTML = card('clients', p.text, s2, ''); speak(s2); return Promise.resolve(); }
    return rpc('eva_query', { p_intent: 'client_detail', p_args: p.args.client_id ? { client_id: p.args.client_id } : { client: p.args.client }, p_command: p.text }).then(function(r){
      var d = r.data || {};
      if (!d.client){ var out = noClient(p, d, p.intent, p.args); holder.outerHTML = out.html; speak(out.say); return; }
      setCtx(d.client);
      return then(d);
    }, function(e){ holder.outerHTML = errorCard(errText(e), p.text); speak(errText(e)); });
  }
  function say(holder, html, s){ holder.outerHTML = html; speak(s); }
  var KIND_AGENT = { reschedule: 'planning', booking_confirm: 'planning', booking_create: 'planning', booking_cancel: 'planning', report_notes: 'planning',
    quote_draft: 'devis', service_create: 'devis', service_publish: 'devis', quote_update: 'devis', quote_send: 'devis',
    client_create: 'clients', client_update: 'clients', referrer_status: 'fidelite', referrer_code: 'fidelite', wallet_adjust: 'fidelite' };
  var CANCEL_REASONS = [['', '— Choisir un motif —'], ['creneau_indisponible', 'Créneau indisponible'], ['hors_zone', 'Hors zone d’intervention'], ['prestation_non_proposee', 'Prestation non proposée'],
    ['client_injoignable', 'Client injoignable'], ['doublon', 'Doublon'], ['erreur_reservation', 'Erreur de réservation'], ['autre', 'Autre (préciser)']];
  var CLIENT_FIELDS = [['first_name', 'Prénom', 'text', 80], ['last_name', 'Nom', 'text', 80], ['phone', 'Téléphone', 'tel', 20], ['email', 'E-mail', 'email', 160],
    ['address', 'Adresse', 'text', 200], ['postal_code', 'Code postal', 'text', 10], ['city', 'Ville', 'text', 80]];

  function runFlow(p, holder){
    var a = p.args || {};
    switch (p.intent){
      case 'client_create': {
        var fields = CLIENT_FIELDS.map(function(f){ return { name: f[0], label: f[1], type: f[2], max: f[3], value: a[f[0]] || '' }; })
          .concat([{ name: 'client_type', label: 'Type', type: 'select', value: 'particulier', options: [['particulier', 'Particulier'], ['professionnel', 'Professionnel']] }, { name: 'notes', label: 'Notes (facultatif)', type: 'textarea', max: 500 }]);
        fields[1].required = true;
        say(holder, formCard(p, 'Nouvelle fiche client : vérifiez puis préparez la création.', { kind: 'client_create', fields: fields, submit: 'Préparer la création',
          build: function(v){ if (!v.phone && !v.email) throw new Error('Indiquez un téléphone ou un e-mail.'); return v; } }), 'Complétez la fiche du nouveau client.');
        return;
      }
      case 'move_to': return withClient(p, holder, function(d){
        var c = d.client, today = I.iso(new Date()), up = (d.bookings || []).filter(function(x){ return (x.status === 'PENDING' || x.status === 'CONFIRMED') && x.date >= today && (!a.from_date || x.date === a.from_date); });
        if (!up.length){ var s0 = 'Aucun rendez-vous à venir pour ' + c.name + '.'; say(holder, card('planning', p.text, s0, ''), s0); return; }
        if (up.length > 1){ var s1 = c.name + ' a ' + up.length + ' rendez-vous à venir : précisez la date actuelle, par exemple « déplace le rendez-vous du 14/01 de ' + c.name + ' à vendredi 10 h ».'; say(holder, card('planning', p.text, s1, ''), s1); return; }
        var b0 = up[0];
        if (!a.to_time){
          return rpc('eva_run', { p_intent: 'free_slots', p_args: { from: a.to_date, to: a.to_date, duration: 60 }, p_command: p.text }).then(function(r){
            var out = renderSlots({ text: p.text }, r.data, { booking_id: b0.booking_id, reference: b0.reference }); holder.outerHTML = out.html; speak('Choisissez l’heure pour ' + c.name + '.');
          });
        }
        holder.outerHTML = card('planning', p.text, 'Rendez-vous de ' + c.name + ' (' + fdate(b0.date) + ' à ' + b0.start + ') vers le ' + fdate(a.to_date) + ' à ' + a.to_time + '.', '');
        return propose('reschedule', { booking_id: b0.booking_id, date: a.to_date, start: a.to_time }, key(), null);
      });
      case 'booking_confirm': return withClient(p, holder, function(d){
        var c = d.client, today = I.iso(new Date()), pend = (d.bookings || []).filter(function(x){ return x.status === 'PENDING' && x.date >= today; });
        if (!pend.length){ var s0 = 'Aucune demande de rendez-vous en attente pour ' + c.name + '.'; say(holder, card('planning', p.text, s0, ''), s0); return; }
        holder.outerHTML = card('planning', p.text, pend.length > 1 ? pend.length + ' demandes en attente pour ' + c.name + ' : la plus proche est proposée.' : 'Demande de ' + c.name + ' : ' + fdate(pend[pend.length - 1].date) + ' à ' + pend[pend.length - 1].start + '.', '');
        return propose('booking_confirm', { booking_id: pend[pend.length - 1].booking_id }, key(), null);
      });
      case 'client_update': return withClient(p, holder, function(d){
        var c = d.client, orig = {};
        var fields = CLIENT_FIELDS.map(function(f){ orig[f[0]] = c[f[0]] || ''; return { name: f[0], label: f[1], type: f[2], max: f[3], value: c[f[0]] || '' }; })
          .concat([{ name: 'notes', label: 'Notes', type: 'textarea', max: 500, value: c.notes || '' }]);
        orig.notes = c.notes || '';
        say(holder, formCard(p, 'Fiche de ' + c.name + ' : modifiez les champs voulus.', { kind: 'client_update', fields: fields, submit: 'Voir les modifications',
          build: function(v){ var ch = {}; Object.keys(v).forEach(function(k){ if ((v[k] || '') !== orig[k]) ch[k] = v[k] || null; }); if (!Object.keys(ch).length) throw new Error('Aucune modification.'); return { client_id: c.client_id, changes: ch }; } }), 'Modifiez la fiche de ' + c.name + '.');
      });
      case 'booking_create': return withClient(p, holder, function(d){
        var c = d.client;
        return rpc('eva_query', { p_intent: 'catalog', p_args: { query: a.service || '' }, p_command: null }).then(function(r){
          var it = (r.data && r.data.items) || [];
          var go = function(items, note){
            var opts = [['', '— Choisir la prestation —']].concat(items.map(function(x){ return [x.kind + ':' + x.id, x.label + ' · ' + priceText(x) + (x.duration_minutes ? ' · ' + x.duration_minutes + ' min' : '')]; }));
            var fields = [{ name: 'svc', label: 'Prestation', type: 'select', options: opts, required: true, value: items.length === 1 ? items[0].kind + ':' + items[0].id : '' },
              { name: 'date', label: 'Date', type: 'date', value: a.date || '', required: true }, { name: 'start', label: 'Heure', type: 'time', value: a.time || '', required: true },
              { name: 'status', label: 'Statut', type: 'select', value: 'CONFIRMED', options: [['CONFIRMED', 'Confirmé (le client est prévenu)'], ['PENDING', 'À confirmer (aucun message)']] },
              { name: 'notes', label: 'Notes (facultatif)', type: 'textarea', max: 500 }];
            say(holder, formCard(p, 'Nouveau rendez-vous pour ' + c.name + '.', { kind: 'booking_create', fields: fields, submit: 'Vérifier le créneau', intro: note || '',
              build: function(v){ var s = v.svc.split(':'); var o = { client_id: c.client_id, date: v.date, start: v.start, status: v.status, notes: v.notes }; o[s[0] === 'pack' ? 'pack_id' : 'service_id'] = s[1]; return o; } }), 'Choisissez la prestation et l’horaire pour ' + c.name + '.');
          };
          if (it.length || !a.service) return go(it);
          return rpc('eva_query', { p_intent: 'catalog', p_args: { query: '' }, p_command: null }).then(function(r2){ go((r2.data && r2.data.items) || [], '<div class="eva-warn"><p>« ' + esc(a.service) + ' » ne correspond à aucune prestation : choisissez dans votre catalogue.</p></div>'); });
        });
      });
      case 'booking_cancel': {
        var pick = function(list, who){
          var today = I.iso(new Date());
          list = list.filter(function(x){ return (x.status === 'PENDING' || x.status === 'CONFIRMED') && x.date >= today && (!a.date || x.date === a.date); });
          if (!list.length){ var s0 = 'Aucun rendez-vous à venir à annuler' + (who ? ' pour ' + who : '') + (a.date ? ' le ' + fdate(a.date) : '') + '.'; say(holder, card('planning', p.text, s0, ''), s0); return; }
          var fields = [{ name: 'booking_id', label: list.length > 1 ? 'Quel rendez-vous ?' : 'Rendez-vous', type: 'radio', options: list.map(function(x){ return [x.booking_id, fdate(x.date) + ' à ' + x.start + ' — ' + x.service + ' (' + (x.client || who || '') + ')', (BSTATUS[x.status] || [''])[0]]; }) },
            { name: 'reason_code', label: 'Motif', type: 'select', options: CANCEL_REASONS, required: true }, { name: 'detail', label: 'Précision (obligatoire si « Autre »)', type: 'textarea', max: 300 }];
          say(holder, formCard(p, list.length > 1 ? list.length + ' rendez-vous possibles : choisissez celui à annuler.' : 'Rendez-vous à annuler : ' + fdate(list[0].date) + ' à ' + list[0].start + '.', { kind: 'booking_cancel', fields: fields, submit: 'Préparer l’annulation',
            build: function(v){ if (v.reason_code === 'autre' && !v.detail) throw new Error('Précisez le motif.'); return v; } }), 'Choisissez le motif d’annulation.');
        };
        if (a.client || a.client_id || p.ctxMissing) return withClient(p, holder, function(d){ pick(d.bookings || [], d.client.name); });
        if (!a.date){ var s1 = 'Quel rendez-vous ? Précisez le client ou la date, par exemple « annule le rendez-vous de Monsieur Dupont jeudi ».'; say(holder, card('planning', p.text, s1, ''), s1); return; }
        return rpc('eva_run', { p_intent: 'agenda', p_args: { date: a.date }, p_command: p.text }).then(function(r){ pick((r.data.interventions || []).map(function(x){ return Object.assign({ date: r.data.date }, x); })); }, function(e){ holder.outerHTML = errorCard(errText(e), p.text); });
      }
      case 'service_create': {
        var fields2 = [{ name: 'name', label: 'Nom de la prestation', value: a.name || '', required: true, max: 120 },
          { name: 'category', label: 'Catégorie', type: 'select', required: true, options: [['', '— Choisir —'], ['plomberie', 'Plomberie'], ['chauffage', 'Chauffage'], ['climatisation', 'Climatisation']] },
          { name: 'mode', label: 'Type de prix', type: 'select', value: 'FIXED', options: [['FIXED', 'Prix fixe'], ['FROM', 'À partir de'], ['QUOTE', 'Sur devis']] },
          { name: 'price_cents', label: 'Prix TTC (€) — saisi par vous', type: 'eur' }, { name: 'duration_minutes', label: 'Durée (minutes)', type: 'number', min: 15, step: 5 },
          { name: 'description', label: 'Description (facultatif)', type: 'textarea', max: 600 }];
        say(holder, formCard(p, 'Nouvelle prestation : EVA n’invente aucun tarif, saisissez-le.', { kind: 'service_create', fields: fields2, submit: 'Préparer l’ajout',
          intro: '<p class="eva-note" style="margin-top:-4px">Elle sera créée masquée ; vous la publierez ensuite d’un geste.</p>',
          build: function(v){ if (v.mode !== 'QUOTE' && !(v.price_cents > 0)) throw new Error('Saisissez le prix.'); if (v.mode !== 'QUOTE' && !v.duration_minutes) throw new Error('Saisissez la durée.'); return v; } }), 'Complétez la nouvelle prestation.');
        return;
      }
      case 'quote_update': case 'quote_send': return withClient(p, holder, function(d){
        var c = d.client, drafts = (d.quotes || []).filter(function(q){ return q.status === 'DRAFT'; });
        if (!drafts.length){ var s = c.name + ' n’a aucun devis en brouillon.'; say(holder, card('devis', p.text, s, '<div class="eva-actions">' + runBtn('Préparer un devis', 'quote_estimate', { client_id: c.client_id, service: '' }, 'Devis — ' + c.name) + '</div>'), s); return; }
        var ch = { name: 'quote_id', label: drafts.length > 1 ? 'Quel devis ?' : 'Devis', type: 'radio', options: drafts.map(function(q){ return [q.quote_id, (q.title || 'Devis') + ' · ' + (q.reference || ''), eur(q.total_cents)]; }) };
        if (p.intent === 'quote_send'){
          say(holder, formCard(p, drafts.length > 1 ? drafts.length + ' brouillons pour ' + c.name + ' : lequel envoyer ?' : 'Devis prêt à envoyer à ' + c.name + ' : ' + eur(drafts[0].total_cents) + '.', { kind: 'quote_send', fields: [ch], submit: 'Préparer l’envoi',
            build: function(v){ return { quote_id: v.quote_id }; } }), 'Vérifiez le devis à envoyer à ' + c.name + '.');
          return;
        }
        var fields3 = [ch, { name: 'title', label: 'Titre (vide = inchangé)', max: 160, placeholder: drafts[0].title || '' }, { name: 'supply_cents', label: 'Fournitures (€, vide = inchangé)', type: 'eur' },
          { name: 'labor_cents', label: 'Main-d’œuvre (€, vide = inchangé)', type: 'eur' }, { name: 'travel_fee_cents', label: 'Déplacement (€, vide = inchangé)', type: 'eur' },
          { name: 'description', label: 'Description (vide = inchangée)', type: 'textarea', max: 1000 }];
        say(holder, formCard(p, 'Modifier un devis de ' + c.name + ' : saisissez seulement ce qui change.', { kind: 'quote_update', fields: fields3, submit: 'Voir le nouveau total',
          build: function(v){ var o = { quote_id: v.quote_id }; ['title', 'description', 'supply_cents', 'labor_cents', 'travel_fee_cents'].forEach(function(k){ if (v[k] !== '' && v[k] != null) o[k] = v[k]; }); if (Object.keys(o).length < 2) throw new Error('Aucune modification.'); return o; } }), 'Modifiez le devis de ' + c.name + '.');
      });
      case 'report': return withClient(p, holder, function(d){
        var c = d.client, list = (d.bookings || []).filter(function(x){ return x.status === 'COMPLETED' || x.status === 'IN_PROGRESS'; });
        if (!list.length){ var s = 'Aucune intervention commencée ou terminée chez ' + c.name + '.'; say(holder, card('planning', p.text, s, ''), s); return; }
        return openReport(p, holder, list[0], list.slice(1, 4));
      });
      case 'referrer_admin': return withClient(p, holder, function(d){
        var c = d.client;
        if (!d.referral){ var s = c.name + ' n’est pas parrain (aucun code de parrainage).'; say(holder, card('fidelite', p.text, s, ''), s); return; }
        if (a.status){ holder.outerHTML = card('fidelite', p.text, c.name + ' : code ' + d.referral.code + ', statut ' + (d.referral.status === 'active' ? 'actif' : d.referral.status) + '.', ''); return propose('referrer_status', { client_id: c.client_id, status: a.status }, key(), null); }
        say(holder, formCard(p, 'Code actuel de ' + c.name + ' : ' + d.referral.code + '.', { kind: 'referrer_code', fields: [{ name: 'code', label: 'Nouveau code (6 à 12 lettres ou chiffres)', value: a.code || '', required: true, max: 12 }], submit: 'Préparer le changement',
          build: function(v){ return { client_id: c.client_id, code: v.code.toUpperCase().replace(/\s/g, '') }; } }), 'Saisissez le nouveau code.');
      });
      case 'wallet_adjust': return withClient(p, holder, function(d){
        var c = d.client, amt = a.amount;
        var fields4 = [{ name: 'dir', label: 'Opération', type: 'select', value: amt < 0 ? 'debit' : 'credit', options: [['credit', 'Créditer (geste commercial, correction)'], ['debit', 'Débiter']] },
          { name: 'amount', label: 'Montant (€)', type: 'eur', value: amt ? Math.round(Math.abs(amt) * 100) : '', required: true }, { name: 'reason', label: 'Motif (obligatoire)', type: 'textarea', max: 300, required: true }];
        say(holder, formCard(p, 'Crédit fidélité de ' + c.name + ' : ' + eur(d.wallet_cents || 0) + ' actuellement.', { kind: 'wallet_adjust', fields: fields4, submit: 'Préparer l’opération',
          build: function(v){ if (!(v.amount > 0)) throw new Error('Montant invalide.'); return { client_id: c.client_id, amount_cents: (v.dir === 'debit' ? -1 : 1) * v.amount, reason: v.reason }; } }), 'Indiquez le montant et le motif.');
      });
    }
  }
  function openReport(p, holder, bk, others){
    return rpc('eva_query', { p_intent: 'report', p_args: { booking_id: bk.booking_id }, p_command: p.text }).then(function(r){
      var d = r.data || {}, iv = d.intervention, head = bk.service + ' — ' + fdate(bk.date) + ' (' + bk.reference + ')';
      var more = others && others.length ? '<p class="eva-h">Autres interventions</p><div class="eva-actions" style="margin-top:0">' + others.map(function(x){ return actBtn(fdate(x.date) + ' · ' + x.service, 'report-open', { p: p, bk: x }); }).join('') + '</div>' : '';
      if (!iv){ var s = 'Aucune fiche d’intervention pour ' + head + ' : commencez l’intervention depuis le planning.'; say(holder, card('planning', p.text, s, more), s); return; }
      if (iv.report_status === 'FINALIZED'){
        var s2 = 'Compte rendu ' + (iv.report_number || '') + ' déjà validé' + (iv.signed ? ' et signé' : '') + ' : il ne peut plus être modifié.';
        say(holder, card('planning', p.text, s2, (iv.observations ? '<p class="eva-h">Observations</p><p class="eva-note" style="margin:0">' + esc(iv.observations) + '</p>' : '') + (iv.recommendations ? '<p class="eva-h">Recommandations</p><p class="eva-note" style="margin:0">' + esc(iv.recommendations) + '</p>' : '') + more), s2);
        return;
      }
      say(holder, formCard(p, 'Compte rendu en brouillon : ' + head + '.', { kind: 'report_notes', submit: 'Préparer l’enregistrement',
        intro: '<p class="eva-note" style="margin-top:-4px">Dictez avec le micro du clavier. La validation, les signatures et l’envoi restent dans la fiche d’intervention.</p>' + more,
        fields: [{ name: 'observations', label: 'Observations', type: 'textarea', rows: 4, max: 4000, value: iv.observations || '' }, { name: 'recommendations', label: 'Recommandations', type: 'textarea', rows: 3, max: 4000, value: iv.recommendations || '' }],
        build: function(v){ if (!v.observations && !v.recommendations) throw new Error('Saisissez des observations ou des recommandations.'); return { booking_id: bk.booking_id, observations: v.observations, recommendations: v.recommendations }; } }), 'Complétez le compte rendu.');
    }, function(e){ holder.outerHTML = errorCard(errText(e), p.text); });
  }
  // Horaires : lus depuis le serveur ; la modification se fait dans Réglages (bouton Enregistrer = action explicite).
  function workHours(p){
    var holder = addCard('<div class="eva-card"><p class="eva-empty">Je consulte vos horaires…</p></div>');
    return rpc('eva_overview').then(function(o){
      var wh = (o.work && o.work.work_hours) || {}, lines = DAY_NAMES.map(function(n, i){ var r = wh[String(i + 1)] || []; return n + ' : ' + (r.length ? r.map(function(x){ return x[0] + '–' + x[1]; }).join(' et ') : 'fermé'); });
      var sum = p.args.view ? 'Vos horaires de travail actuels.' : 'Vos horaires se modifient dans les réglages d’EVA ; ils s’appliquent aussi aux créneaux proposés sur le site.';
      holder.outerHTML = card('planning', p.text, sum, '<ul class="eva-list">' + lines.map(function(l){ return '<li class="eva-item"><div class="eva-main"><b>' + esc(l) + '</b></div></li>'; }).join('') + '</ul>' +
        '<p class="eva-note">Marge de trajet : ' + esc((o.work && o.work.travel_margin_minutes) != null ? o.work.travel_margin_minutes : 30) + ' min.</p>' +
        '<div class="eva-actions"><button type="button" class="eva-btn sm cu" data-act="tab" data-tab="settings">Modifier mes horaires</button></div>');
      speak(sum);
    }, function(e){ holder.outerHTML = errorCard(errText(e), p.text); speak(errText(e)); });
  }
  function askService(p, holder){
    holder.outerHTML = card('devis', p.text, 'Quelle prestation faut-il chiffrer' + (p.args.client ? ' pour ' + p.args.client : '') + ' ?',
      '<div class="eva-set eva-form"><label class="eva-field">Prestation<input type="text" data-f="service" maxlength="120" placeholder="Ex. : remplacement du mitigeur"></label>' +
      '<div class="eva-actions" style="margin-top:4px">' + actBtn('Chercher dans mon catalogue', 'ask-service', { p: p }, 'cu') + '</div></div>');
    speak('Quelle prestation faut-il chiffrer ?');
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
  function propose(kind, payload, idem, btn, msgEl){
    if (btn) btn.disabled = true;
    return rpc('eva_propose', { p_kind: kind, p_payload: payload, p_idem_key: idem }).then(function(r){
      if (r.duplicate) return loadOverview().then(function(){ setTab('proposals'); });
      var agent = KIND_AGENT[kind] || 'factures';
      addCard(proposalCard({ proposal_id: r.proposal_id, level: r.level, agent: agent, title: r.title, consequences: r.consequences, status: 'PENDING' }, true));
      updateBadge();
    }, function(e){
      if (btn) btn.disabled = false;
      if (msgEl){ msgEl.hidden = false; msgEl.className = 'eva-msg no'; msgEl.textContent = errText(e); } else addCard(errorCard(errText(e)));
      speak(errText(e));
    });
  }
  function confirmProp(id, btn){
    var cardEl = btn.closest('[data-prop]'), msg = cardEl.querySelector('[data-role="msg"]');
    cardEl.querySelectorAll('button').forEach(function(b){ b.disabled = true; });
    rpcAuth('eva_confirm_proposal', { p_id: id, p_confirm: true }).then(function(r){
      if (!r.ok){ msg.hidden = false; msg.className = 'eva-msg no'; msg.textContent = r.error || 'Action non réalisée.'; return; }
      var res = r.result || {}, txt = 'Fait.', page = null;
      var extra = '';
      if (res.client_created){ txt = 'Fiche client créée.'; page = 'clients'; extra = runBtn('Ouvrir la fiche', 'client_detail', { client_id: res.client_id }, 'Fiche du nouveau client'); }
      else if (res.client_updated){ txt = 'Fiche client mise à jour.'; page = 'clients'; extra = runBtn('Voir la fiche', 'client_detail', { client_id: res.client_id }, 'Fiche client'); }
      else if (res.booking_created){ txt = 'Rendez-vous ' + (res.reference || '') + ' créé le ' + dayLabel(res.date) + ' à ' + res.start + (res.status === 'CONFIRMED' ? ' et confirmé : le client est prévenu, le calendrier est mis à jour.' : ', à confirmer.'); page = 'planning'; }
      else if (res.booking_cancelled){ txt = 'Rendez-vous annulé. Il reste dans l’historique ; le client est prévenu.'; page = 'planning'; }
      else if (res.service_created){ txt = 'Prestation « ' + (res.name || '') + ' » ajoutée, masquée pour vos clients.'; page = 'catalog'; extra = actBtn('Publier sur le site', 'prop', { kind: 'service_publish', payload: { service_id: res.service_id }, idem: key() }, 'cu'); }
      else if (res.service_published){ txt = 'Prestation publiée : elle est visible et réservable.'; page = 'catalog'; }
      else if (res.quote_updated){ txt = 'Devis modifié. Nouveau total : ' + eur(res.total_cents) + '. Il reste un brouillon.'; page = 'quotes'; }
      else if (res.quote_sent){ txt = 'Devis envoyé au client' + (res.reference ? ' (' + res.reference + ')' : '') + '.'; page = 'quotes'; }
      else if (res.report_saved){ txt = 'Compte rendu enregistré en brouillon. Validez et faites signer depuis la fiche d’intervention.'; page = 'interventions'; }
      else if (res.referrer_status){ txt = res.referrer_status === 'active' ? 'Parrain réactivé.' : 'Parrain suspendu.'; page = 'referrals'; }
      else if (res.referrer_code){ txt = 'Code de parrainage changé en ' + res.referrer_code + '.'; page = 'referrals'; }
      else if (res.wallet_adjusted){ txt = 'Crédit fidélité mis à jour : solde ' + eur(res.balance_cents) + '.'; }
      else if (res.payment){ txt = 'Paiement enregistré.' + (res.invoice_status === 'PAID' ? ' La facture est entièrement réglée.' : ' La facture reste partiellement réglée.'); page = 'invoices'; }
      else if (res.issued){ txt = 'Facture émise : ' + (res.reference || '') + '. Elle est désormais définitive.'; page = 'invoices'; }
      else if (res.quote_id){ txt = 'Brouillon de devis ' + (res.reference || '') + ' créé. Complétez-le puis envoyez-le depuis la rubrique Devis.'; page = 'quotes'; }
      else if (res.invoice_id){ txt = 'Brouillon de facture prêt' + (res.reference ? ' (' + res.reference + ')' : '') + '. Vérifiez-le dans la rubrique Factures avant toute émission.'; page = 'invoices'; }
      else if (res.confirmed){ txt = 'Rendez-vous confirmé. Le client reçoit l’e-mail de confirmation, le rendez-vous est ajouté à Apple Calendar.'; page = 'planning'; }
      else if (res.booking_id){ txt = 'Rendez-vous déplacé au ' + dayLabel(res.date) + ' à ' + res.start + '. Le client est prévenu, le calendrier est mis à jour.'; page = 'planning'; }
      cardEl.querySelectorAll('.eva-actions, .eva-check').forEach(function(x){ x.remove(); });
      msg.hidden = false; msg.className = 'eva-msg ok'; msg.textContent = txt; speak(txt);
      loadToday();
      if (page || extra) msg.insertAdjacentHTML('afterend', '<div class="eva-actions">' + extra + (page ? '<button type="button" class="eva-btn sm ghost" data-act="goto" data-page="' + page + '">Ouvrir la rubrique</button>' : '') + '</div>');
      updateBadge();
    }, function(e){
      msg.hidden = false; msg.className = 'eva-msg no'; msg.textContent = errText(e); speak(errText(e));
      cardEl.querySelectorAll('[data-act="cancel"]').forEach(function(b){ b.disabled = false; });
      var ack = cardEl.querySelector('[data-role="ack"]'), cf = cardEl.querySelector('[data-act="confirm"]');
      if (cf) cf.disabled = !!(ack && !ack.checked);
    });
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
  // RGPD : efface le TEXTE des conversations (demandes, réponses lues) ; les traces des
  // actions proposées ou confirmées restent, pour l'historique des opérations.
  function clearHistory(b){
    if (!window.confirm('Effacer le texte de vos conversations avec EVA ?\n\nLes traces des actions proposées ou confirmées sont conservées.')) return;
    b.disabled = true;
    rpc('eva_clear_history', {}).then(function(r){
      feed.innerHTML = ''; state.last = null; state.ctx = null;
      hintEl.textContent = (r && r.cleared != null ? r.cleared : 0) + ' conversation(s) effacée(s).';
      loadOverview();
    }, function(e){ b.disabled = false; hintEl.textContent = errText(e); });
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
  var INT = { agenda: 'Interventions', free_slots: 'Créneaux libres', conflicts: 'Conflits', find_client: 'Recherche client', quote_estimate: 'Chiffrage', quotes_pending: 'Devis', invoices_todo: 'Factures', attention: 'Attention', brief: 'Ma journée', agenda_range: 'Rendez-vous de la période', stats: 'Statistiques', catalog: 'Catalogue', invoices_list: 'Factures et paiements',
    client_detail: 'Fiche client', loyalty: 'Fidélité', maintenance_due: 'Entretiens à renouveler', referrals: 'Parrainage', report: 'Compte rendu' };
  function renderHistory(o){
    var j = o.journal || [];
    root.querySelector('[data-pane="history"]').innerHTML = '<p class="eva-h" style="margin-top:4px">Vos dernières actions (' + (o.today_count || 0) + ' aujourd’hui)</p>' +
      '<p class="eva-note">Aucun enregistrement audio n’est conservé : seul le texte de vos demandes est noté. ' +
      '<button type="button" class="eva-btn sm ghost" data-act="clear-history">Effacer le texte de mes conversations</button></p>' +
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
        ['planning', 'devis', 'factures', 'clients', 'fidelite'].map(function(k){ return '<label class="eva-toggle"><span>' + AGENT[k] + '</span><input type="checkbox" data-set="agent" data-agent="' + k + '"' + (ag[k] ? ' checked' : '') + '></label>'; }).join('') +
        '<label class="eva-toggle"><span>Lire les réponses à voix haute après une dictée</span><input type="checkbox" data-set="tts"' + (tts ? ' checked' : '') + '></label>' +
        (SR ? '<label class="eva-toggle"><span>Proposer le mode mains libres « Dis EVA » (expérimental, sur cet appareil)</span><input type="checkbox" data-set="handsfree"' + (hfAllowed() ? ' checked' : '') + '></label>' +
          '<p class="eva-note" style="margin:-2px 0 0">Uniquement quand EVA est ouverte et l’écran allumé, après avoir touché « Écouter “Dis EVA” ». La reconnaissance vocale du navigateur est utilisée (sur iPhone : la dictée d’Apple, qui traite l’audio sur ses serveurs). Seules les phrases commençant par « EVA » sont prises en compte ; le reste est ignoré et jamais enregistré. Arrêt automatique après 3 minutes sans « EVA ».</p>' : '') +
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
      '<p class="eva-h">Micro</p><p class="eva-note" style="margin-top:-4px">' + esc(micInfo()) + '</p>' +
      '<p class="eva-h">« Dis Siri, EVA »</p><div data-role="siri"><p class="eva-empty">Chargement…</p></div>';
    loadSiri();
  }
  // ------------------------------------------------ Siri (lecture seule)
  function fnUrl(){ var c = sb(); return ((c && c.supabaseUrl) || 'https://hvlzdsuyhrhaflwutwml.supabase.co').replace(/\/$/, '') + '/functions/v1/eva-siri'; }
  function loadSiri(keep){
    keep = keep || {};
    var box = root.querySelector('[data-pane="settings"] [data-role="siri"]'); if (!box) return;
    rpc('eva_devices_list').then(function(d){
      var dv = d.devices || [], act = dv.filter(function(x){ return x.active; });
      box.innerHTML = '<p class="eva-note" style="margin-top:-4px">Posez vos questions à EVA par Siri grâce à un raccourci iPhone. <b>Lecture seule</b> : par la voix, EVA répond (planning, devis, factures, clients) mais n’agit jamais ; pour créer, envoyer ou annuler, elle vous renvoie dans l’application. Gratuit : aucun service payant.</p>' +
        '<div class="eva-set">' +
          '<label class="eva-toggle"><span>Autoriser les questions par Siri</span><input type="checkbox" data-set="siri"' + (d.siri_enabled ? ' checked' : '') + '></label>' +
          (dv.length ? '<ul class="eva-list">' + dv.map(function(x){
            return '<li class="eva-item"><div class="eva-main"><b>' + esc(x.label) + '</b><span>' + (x.scope === 'propose' ? 'Questions + préparation d’actions' : 'Questions seulement') + '</span><span>Jeton …' + esc(x.hint) + ' · ' + (x.last_used_at ? 'utilisé le ' + esc(new Date(x.last_used_at).toLocaleDateString('fr-FR')) + ' (' + x.use_count + ' fois)' : 'jamais utilisé') + '</span>' +
              '<span>' + (x.active ? 'Expire le ' + esc(new Date(x.expires_at).toLocaleDateString('fr-FR')) : x.revoked_at ? 'Révoqué le ' + esc(new Date(x.revoked_at).toLocaleDateString('fr-FR')) : 'Expiré') + '</span>' +
              (x.active ? '<div class="eva-actions">' + actBtn('Révoquer', 'siri-revoke', { id: x.id, label: x.label }) + '</div>' : '') + '</div>' +
              '<span class="eva-pill ' + (x.active ? 'ok' : 'no') + '">' + (x.active ? 'Actif' : 'Inactif') + '</span></li>';
          }).join('') + '</ul>' : '') +
          (act.length < 5 ? '<label class="eva-field">Nom de l’appareil<input type="text" maxlength="60" data-role="siri-label" placeholder="Ex. : iPhone de Julien"></label>' +
            '<label class="eva-check"><input type="checkbox" data-role="siri-scope" checked> <span>Autoriser Siri à <b>préparer</b> des actions (fiche client, devis et facture en brouillon, confirmer ou déplacer un rendez-vous). Rien n’est exécuté sans votre confirmation dans EVA.</span></label>' +
            '<label class="eva-check"><input type="checkbox" data-role="siri-ack"> <span>Je garde ce jeton pour moi : il permet de consulter mon planning et mes clients. Je pourrai le révoquer à tout moment.</span></label>' +
            '<div class="eva-actions" style="margin-top:0"><button type="button" class="eva-btn cu" data-act="siri-create" disabled>Créer l’accès Siri pour cet iPhone</button></div>' : '<p class="eva-note">Cinq appareils actifs au maximum.</p>') +
          '<div data-role="siri-token">' + (keep.token || '') + '</div><p class="eva-msg' + (keep.msg ? ' ok' : '') + '" data-role="siri-msg"' + (keep.msg ? '' : ' hidden') + '>' + esc(keep.msg || '') + '</p>' +
        '</div>' +
        '<details class="eva-howto"><summary>Créer le raccourci « EVA » sur l’iPhone (2 minutes)</summary><ol>' +
          '<li>Ouvrez l’app <b>Raccourcis</b>, touchez <b>+</b> et nommez le raccourci <b>EVA</b>.</li>' +
          '<li>Ajoutez l’action <b>Demander une entrée</b> (type Texte), question : « Que souhaitez-vous faire ? ». Siri la pose à voix haute et écoute votre réponse.</li>' +
          '<li>Ajoutez <b>Obtenir le contenu de l’URL</b> : adresse <code>' + esc(fnUrl()) + '</code>, méthode <b>POST</b>, en-tête <code>x-eva-token</code> = votre jeton, corps <b>JSON</b> avec la clé <code>text</code> = <b>Entrée fournie</b>.</li>' +
          '<li>Ajoutez <b>Énoncer le texte</b> avec le <b>Contenu de l’URL</b>.</li>' +
          '<li>Dites : « <b>Dis Siri, EVA</b> », puis votre question, par exemple « qu’est-ce que j’ai demain ? ».</li>' +
        '</ol><p class="eva-note">Siri ouvre le raccourci, vous dictez, EVA répond à voix haute. iOS n’autorise aucune application à écouter en permanence : c’est Siri qui lance EVA.</p></details>';
    }, function(e){ box.innerHTML = '<p class="eva-note">' + esc(/PGRST202|Could not find|does not exist/i.test(String(e && e.message)) ? 'Accès Siri disponible après installation de la migration 0137 et de la fonction eva-siri (à valider).' : errText(e)) + '</p>'; });
  }
  function siriMsg(t, cls){ var m = root.querySelector('[data-role="siri-msg"]'); if (m){ m.hidden = false; m.className = 'eva-msg ' + (cls || ''); m.textContent = t; } }
  function siriCreate(b){
    var lab = root.querySelector('[data-role="siri-label"]').value.trim();
    if (lab.length < 2) return siriMsg('Nommez l’appareil, par exemple « iPhone de Julien ».', 'no');
    b.disabled = true;
    var scopeEl = root.querySelector('[data-role="siri-scope"]');
    rpcAuth('eva_device_create', { p_label: lab, p_days: 365, p_scope: scopeEl && scopeEl.checked ? 'propose' : 'read' }).then(function(r){
      var html = '<div class="eva-warn" style="background:rgba(95,199,149,.1);color:#9BE0BD"><p>Jeton de « ' + esc(lab) + ' » : copiez-le maintenant dans le raccourci. Il ne sera plus jamais affiché.</p></div>' +
        '<div class="eva-token"><code data-role="siri-token-value">' + esc(r.token) + '</code><button type="button" class="eva-btn sm cu" data-act="siri-copy">Copier</button></div>' +
        '<p class="eva-note">Valable jusqu’au ' + esc(new Date(r.expires_at).toLocaleDateString('fr-FR')) + '. Adresse du raccourci : <code>' + esc(fnUrl()) + '</code></p>';
      loadSiri({ token: html, msg: 'Accès Siri créé.' });
    }, function(e){ b.disabled = false; siriMsg(errText(e), 'no'); });
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
    rpcAuth('admin_set_work_hours', { p_work_hours: out, p_travel_margin: margin }).then(function(){
      btn.disabled = false; msg.className = 'eva-msg ok'; msg.textContent = 'Horaires enregistrés.';
    }, function(e){ btn.disabled = false; msg.className = 'eva-msg no'; msg.textContent = errText(e); });
  }
  function saveVat(btn){
    var pane = root.querySelector('[data-pane="settings"]'), msg = pane.querySelector('[data-role="vat-msg"]');
    var regime = pane.querySelector('[data-role="vat-regime"]').value, rate = regime === 'assujetti' ? Number(pane.querySelector('[data-role="vat-rate"]').value) : null;
    msg.hidden = false;
    if (!regime){ msg.className = 'eva-msg no'; msg.textContent = 'Choisissez un régime.'; return; }
    btn.disabled = true;
    rpcAuth('admin_confirm_vat_regime', { p_regime: regime, p_rate: rate }).then(function(r){
      var n = (r && r.drafts_realigned) || 0;
      msg.className = 'eva-msg ok'; msg.textContent = 'Régime de TVA confirmé.' + (n ? ' ' + n + ' brouillon(s) de facture recalculé(s) au taux confirmé.' : ''); loadOverview();
    }, function(e){ btn.disabled = false; msg.className = 'eva-msg no'; msg.textContent = errText(e); });
  }
  function saveSetting(el){
    var pane = root.querySelector('[data-pane="settings"]'), msg = pane.querySelector('[data-role="set-msg"]');
    if (el.getAttribute('data-set') === 'tts'){ try { localStorage.setItem(TTS_KEY, el.checked ? '1' : '0'); } catch (e){} return; }
    if (el.getAttribute('data-set') === 'handsfree'){ try { localStorage.setItem(HF_KEY, el.checked ? '1' : '0'); } catch (e){} if (!el.checked) hfStop(''); hfBar(); return; }
    if (el.getAttribute('data-set') === 'siri'){
      return rpcAuth('eva_siri_set', { p_enabled: el.checked }).then(function(){ siriMsg(el.checked ? 'Siri autorisé.' : 'Questions par Siri désactivées : tous les iPhone sont refusés.', 'ok'); },
        function(e){ el.checked = !el.checked; siriMsg(errText(e), 'no'); });
    }
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
    if (t.matches('[data-role="siri-ack"]')){ var sb2 = root.querySelector('[data-act="siri-create"]'); if (sb2) sb2.disabled = !t.checked; return; }
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
    if (act === 'form' && o) return submitForm(b, o);
    if (act === 'prop' && o) return propose(o.kind, o.payload, o.idem, b);
    if (act === 'report-open' && o){ var h = addCard('<div class="eva-card"><p class="eva-empty">Je consulte vos données…</p></div>'); return openReport(o.p, h, o.bk, []); }
    if (act === 'ask-service' && o){
      var sv = b.closest('.eva-form').querySelector('[data-f="service"]').value.trim(); if (!sv) return;
      return runOne({ intent: 'quote_estimate', args: Object.assign({}, o.p.args, { service: sv }), text: o.p.text + ' — ' + sv }, o.p.text);
    }
    if (act === 'hf-start') return hfStart();
    if (act === 'hf-stop') return hfStop('Mains libres arrêté.');
    if (act === 'siri-create') return siriCreate(b);
    if (act === 'siri-revoke' && o){
      if (b.getAttribute('data-armed') !== '1'){ b.setAttribute('data-armed', '1'); b.textContent = 'Confirmer la révocation de « ' + o.label + ' »'; b.classList.remove('ghost'); b.classList.add('cu'); return; }
      b.disabled = true;
      return rpc('eva_device_revoke', { p_id: o.id }).then(function(){ loadSiri({ msg: 'Accès révoqué : cet iPhone ne peut plus interroger EVA.' }); }, function(e){ b.disabled = false; siriMsg(errText(e), 'no'); });
    }
    if (act === 'siri-copy'){
      var tv = root.querySelector('[data-role="siri-token-value"]'), txt = tv ? tv.textContent : '';
      var done = function(){ b.textContent = 'Copié'; };
      if (navigator.clipboard && navigator.clipboard.writeText) return navigator.clipboard.writeText(txt).then(done, function(){ selectText(tv); });
      return selectText(tv);
    }
    if (act === 'stop-mic') return state.convo ? endConvo('Conversation terminée.') : stopMic();
    if (act === 'stop-voice') return stopVoice();
    if (act === 'end-convo') return endConvo('Conversation terminée.');
    if (act === 'clear-history') return clearHistory(b);
    if (act === 'confirm') return confirmProp(b.getAttribute('data-id'), b);
    if (act === 'cancel') return cancelProp(b.getAttribute('data-id'), b);
    if (act === 'save-hours') return saveHours(b);
    if (act === 'save-vat') return saveVat(b);
  }

  function selectText(el){ if (!el) return; var r = document.createRange(); r.selectNodeContents(el); var s2 = window.getSelection(); s2.removeAllRanges(); s2.addRange(r); }
  // ----------------------------------------------------------------- micro
  var SR = window.SpeechRecognition || window.webkitSpeechRecognition || null, rec = null;
  // L'écoute arrêtée est oubliée AVANT abort() : ses événements tardifs (fin, résultat) sont ignorés.
  function stopMic(){ var r = rec; rec = null; if (r){ try { r.abort(); } catch (e){} } setListening(false); }
  function listenVeil(){
    var v = root.querySelector('#evaListen');
    if (!v){
      v = document.createElement('div'); v.id = 'evaListen'; v.className = 'eva-listen'; v.setAttribute('role', 'status'); v.setAttribute('aria-live', 'polite');
      v.innerHTML = '<div class="eva-orb"><span class="eva-ring" id="evaRing"></span><img src="' + (location.protocol === 'file:' ? '' : '/') + 'images/brand/hayeva-logo-sm.png" alt="" width="900" height="607"></div>' +
        '<p class="eva-listen-t">EVA vous écoute…</p><p class="eva-listen-q" id="evaListenQ"></p>' +
        '<div class="eva-actions" style="justify-content:center"><button type="button" class="eva-btn ghost" data-act="stop-mic">Arrêter le micro</button>' +
        '<button type="button" class="eva-btn ghost" data-act="end-convo" hidden>Terminer la conversation</button></div>';
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
    updVoice();
  }
  function toggleMic(){
    if (!SR){ hintEl.textContent = 'Dictée indisponible ici : touchez le champ puis le micro de votre clavier.'; input.focus(); return; }
    if (state.listening) return state.convo ? endConvo('Conversation terminée.') : stopMic();
    // Toucher le micro pendant qu'EVA parle l'interrompt et donne la parole.
    if (state.speaking) stopVoice();
    hfStop('');
    // Conversation orale : EVA répond à voix haute puis réécoute, jusqu'à « au revoir », « Terminer » ou un silence.
    state.convo = ttsOn();
    startRec(false);
  }
  function startRec(auto){
    rec = new SR(); rec.lang = 'fr-FR'; rec.interimResults = true; rec.maxAlternatives = 1; rec.continuous = false;
    var finalText = '', mine = rec;
    rec.onresult = function(ev){
      if (rec !== mine) return;
      var txt = ''; for (var i = 0; i < ev.results.length; i++){ txt += ev.results[i][0].transcript; if (ev.results[i].isFinal) finalText = txt; }
      input.value = txt;
      var q = root.querySelector('#evaListenQ'); if (q) q.textContent = '« ' + txt + ' »';
      // L'anneau réagit à la parole reconnue (chaque nouveau fragment = une impulsion).
      pulse(0.55 + Math.min(0.45, (txt.length % 9) / 18)); clearTimeout(state.pulseT); state.pulseT = setTimeout(function(){ pulse(0.15); }, 260);
    };
    rec.onspeechstart = function(){ pulse(0.6); };
    rec.onaudiostart = function(){ pulse(0.2); };
    rec.onerror = function(ev){
      if (rec !== mine) return;
      var denied = ev.error === 'not-allowed' || ev.error === 'service-not-allowed';
      if (auto && !denied && ev.error === 'no-speech') return;
      setListening(false); state.convo = false; updVoice();
      hintEl.textContent = denied ? (auto ? 'Touchez le micro pour continuer la conversation.' : 'Micro refusé : autorisez-le dans les réglages du navigateur, ou utilisez le micro du clavier.')
        : ev.error === 'network' ? 'Dictée interrompue (réseau). Réessayez ou tapez votre commande.' : 'Dictée interrompue. Réessayez ou tapez votre commande.';
    };
    rec.onend = function(){
      if (rec !== mine) return;
      rec = null; setListening(false); var v = (finalText || input.value).trim(); hintEl.textContent = '';
      if (v){ input.value = ''; run(v, true); return; }
      // Silence : la conversation se termine d'elle-même, le micro est coupé.
      if (state.convo){ state.convo = false; updVoice(); hintEl.textContent = auto ? 'Conversation terminée (silence). Touchez le micro pour reprendre.' : ''; }
    };
    try { rec.start(); setListening(true); hintEl.textContent = state.convo ? 'Je vous écoute… (dites « au revoir » ou touchez Terminer pour arrêter)' : 'Je vous écoute… (touchez à nouveau pour arrêter)'; }
    catch (e){ setListening(false); state.convo = false; updVoice(); hintEl.textContent = 'Touchez le micro pour parler.'; }
  }

  // --------------------------------------- mains libres « Dis EVA » (prototype)
  // Écoute UNIQUEMENT pendant qu'EVA est ouverte, visible, après un geste
  // volontaire ; indicateur permanent et bouton d'arrêt ; seules les phrases
  // commençant par « EVA » sont utilisées, les autres sont ignorées.
  var hf = { on: false, rec: null, idleT: null, speaking: false, awaiting: false, restarts: 0, heard: 0 };
  var WAKE = /^\s*(?:(?:dis|hey|ok|bonjour)\s+)?(?:eva|hayeva)\b[\s,.:!-]*(.*)$/i;
  function hfAllowed(){ try { return !!SR && localStorage.getItem(HF_KEY) === '1'; } catch (e){ return false; } }
  function hfIdleMs(){ return Number(window.__EVA_HF_IDLE_MS) || 180000; }
  function hfBar(){
    var bar = root && root.querySelector('#evaHf'); if (!bar) return;
    if (!hfAllowed() && !hf.on){ bar.hidden = true; bar.innerHTML = ''; return; }
    bar.hidden = false;
    bar.className = 'eva-hf' + (hf.on ? ' is-on' : '');
    bar.innerHTML = hf.on
      ? '<span class="eva-hf-dot" aria-hidden="true"></span><span role="status">' + (hf.awaiting ? 'Je vous écoute…' : 'Mains libres : dites « EVA, … »') + '</span><button type="button" class="eva-btn sm ghost" data-act="hf-stop">Arrêter</button>'
      : '<button type="button" class="eva-btn sm ghost" data-act="hf-start">Écouter « Dis EVA »</button>';
  }
  function hfArmIdle(){ clearTimeout(hf.idleT); hf.idleT = setTimeout(function(){ hfStop('Mains libres arrêté après 3 minutes sans « EVA ».'); }, hfIdleMs()); }
  function hfStart(){
    if (!SR || hf.on) return;
    stopMic();
    hf.on = true; hf.awaiting = false; hf.restarts = 0;
    hfArmIdle(); hfListen(); hfBar();
    hintEl.textContent = 'Mains libres actif tant qu’EVA reste ouverte. Dites « EVA » puis votre demande.';
  }
  function hfStop(msg){
    if (!hf.on) return;
    hf.on = false; hf.awaiting = false; clearTimeout(hf.idleT);
    var r = hf.rec; hf.rec = null; if (r) try { r.onend = null; r.abort(); } catch (e){}
    if (msg && hintEl) hintEl.textContent = msg;
    hfBar();
  }
  function hfRestart(){
    if (!hf.on || hf.speaking || !root || root.hidden || document.hidden) return;
    setTimeout(function(){ if (hf.on && !hf.rec && !hf.speaking) hfListen(); }, 250);
  }
  function hfHandle(text){
    var t = String(text || '').trim(); if (!t) return;
    var m = WAKE.exec(t);
    if (hf.awaiting){ hf.awaiting = false; hfArmIdle(); hfBar(); run(m ? (m[1] || '') || t : t, true); return; }
    if (!m) return; // conversation ambiante : ignorée, jamais affichée ni enregistrée
    hf.heard++; hfArmIdle();
    var rest = (m[1] || '').trim();
    if (rest.length > 2) run(rest, true);
    else { hf.awaiting = true; hfBar(); }
  }
  function hfListen(){
    var r;
    try { r = new SR(); } catch (e){ return hfStop('Écoute impossible sur ce navigateur.'); }
    hf.rec = r; r.lang = 'fr-FR'; r.continuous = true; r.interimResults = false; r.maxAlternatives = 1;
    r.onresult = function(ev){
      for (var i = ev.resultIndex || 0; i < ev.results.length; i++){ if (ev.results[i].isFinal !== false) hfHandle(ev.results[i][0].transcript); }
    };
    r.onerror = function(ev){
      if (ev && (ev.error === 'not-allowed' || ev.error === 'service-not-allowed')){ hf.rec = null; hfStop('Micro refusé ou interrompu par le système : touchez « Écouter “Dis EVA” » pour reprendre.'); }
    };
    r.onend = function(){ if (hf.rec === r) hf.rec = null; hf.restarts++; hfRestart(); };
    try { r.start(); } catch (e){ hf.rec = null; hfStop('Le système a interrompu l’écoute : touchez « Écouter “Dis EVA” » pour reprendre.'); }
  }
  document.addEventListener('visibilitychange', function(){ if (document.hidden) hfStop('Mains libres arrêté (écran quitté).'); });

  window.EVA = { open: open, close: close, run: function(t){ if (!root) build(); return run(t, false); },
    handsFreeState: function(){ return { on: hf.on, awaiting: hf.awaiting, restarts: hf.restarts, heard: hf.heard }; } };
})();
