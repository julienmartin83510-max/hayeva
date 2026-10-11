// EVA — interprète de commandes en français (déterministe, sans IA).
// Traduit une phrase en une ou plusieurs intentions d'une liste FERMÉE
// (agenda, free_slots, conflicts, find_client, quote_estimate,
// quotes_pending, invoices_todo, attention, brief). Le serveur (eva_run)
// revérifie tout : cet interprète ne donne aucun droit, il choisit seulement
// la question à poser. Aucune phrase n'est jamais interprétée comme une
// confirmation d'action : les actions passent par un bouton dédié.
(function(root, factory){
  if (typeof module === 'object' && module.exports) module.exports = factory();
  else root.EVAIntents = factory();
})(typeof self !== 'undefined' ? self : this, function(){
  'use strict';

  var DAYS = ['dimanche', 'lundi', 'mardi', 'mercredi', 'jeudi', 'vendredi', 'samedi'];
  var MONTHS = ['janvier', 'fevrier', 'mars', 'avril', 'mai', 'juin', 'juillet', 'aout', 'septembre', 'octobre', 'novembre', 'decembre'];

  function norm(s){
    return String(s || '').toLowerCase().normalize('NFD').replace(/[̀-ͯ]/g, '')
      .replace(/[’']/g, ' ').replace(/[^a-z0-9/:,.\s-]/g, ' ').replace(/\s+/g, ' ').trim();
  }
  function iso(d){ return d.getFullYear() + '-' + String(d.getMonth() + 1).padStart(2, '0') + '-' + String(d.getDate()).padStart(2, '0'); }
  function addDays(d, n){ var x = new Date(d.getFullYear(), d.getMonth(), d.getDate()); x.setDate(x.getDate() + n); return x; }
  function startOfDay(d){ return new Date(d.getFullYear(), d.getMonth(), d.getDate()); }

  // Date ou période citée dans la phrase. Renvoie { date } ou { from, to } ou null.
  function parseWhen(t, now){
    var today = startOfDay(now), m;
    if (/\bapres[ -]demain\b/.test(t)) return { date: iso(addDays(today, 2)), label: 'après-demain' };
    if (/\bdemain\b/.test(t)) return { date: iso(addDays(today, 1)), label: 'demain' };
    if (/\bhier\b/.test(t)) return { date: iso(addDays(today, -1)), label: 'hier' };
    if (/\b(aujourd hui|ce jour|ce matin|cet apres-midi|cet apres midi|ce soir)\b/.test(t)) return { date: iso(today), label: "aujourd'hui" };
    if (/\bsemaine prochaine\b/.test(t)){
      var toMon = (8 - today.getDay()) % 7 || 7;
      var mon = addDays(today, toMon);
      return { from: iso(mon), to: iso(addDays(mon, 5)), label: 'la semaine prochaine' };
    }
    if (/\bcette semaine\b/.test(t)){
      var toSat = (6 - today.getDay() + 7) % 7;
      return { from: iso(today), to: iso(addDays(today, toSat || 0)), label: 'cette semaine' };
    }
    if ((m = /\bdans (\d{1,2}) jours?\b/.exec(t))) return { date: iso(addDays(today, Number(m[1]))), label: 'dans ' + m[1] + ' jours' };
    if ((m = /\b(?:les |des )?(\d{1,2}) prochains jours\b/.exec(t))) return { from: iso(today), to: iso(addDays(today, Math.min(31, Number(m[1])))), label: 'les ' + m[1] + ' prochains jours' };
    // 12/01 ou 12/01/2027
    if ((m = /\b(\d{1,2})\/(\d{1,2})(?:\/(\d{2,4}))?\b/.exec(t))){
      var y = m[3] ? (m[3].length === 2 ? 2000 + Number(m[3]) : Number(m[3])) : today.getFullYear();
      var d1 = new Date(y, Number(m[2]) - 1, Number(m[1]));
      if (!m[3] && d1 < addDays(today, -60)) d1 = new Date(y + 1, Number(m[2]) - 1, Number(m[1]));
      if (d1.getMonth() === Number(m[2]) - 1) return { date: iso(d1), label: 'le ' + d1.toLocaleDateString('fr-FR', { day: 'numeric', month: 'long' }) };
    }
    // le 12 janvier (2027)
    if ((m = new RegExp('\\b(\\d{1,2}|1er) (' + MONTHS.join('|') + ')(?: (\\d{4}))?\\b').exec(t))){
      var day = m[1] === '1er' ? 1 : Number(m[1]), mon2 = MONTHS.indexOf(m[2]);
      var y2 = m[3] ? Number(m[3]) : today.getFullYear();
      var d2 = new Date(y2, mon2, day);
      if (!m[3] && d2 < addDays(today, -60)) d2 = new Date(y2 + 1, mon2, day);
      if (d2.getMonth() === mon2) return { date: iso(d2), label: 'le ' + d2.toLocaleDateString('fr-FR', { day: 'numeric', month: 'long' }) };
    }
    // lundi, mardi prochain… : prochaine occurrence (aujourd'hui exclu)
    if ((m = new RegExp('\\b(' + DAYS.join('|') + ')\\b').exec(t))){
      var target = DAYS.indexOf(m[1]);
      var diff = (target - today.getDay() + 7) % 7 || 7;
      return { date: iso(addDays(today, diff)), label: m[1] };
    }
    return null;
  }

  function parsePeriod(t, now){
    var today = startOfDay(now), dow = (today.getDay() + 6) % 7; // lundi = 0
    if (/\bsemaine derniere\b/.test(t)){ var m0 = addDays(today, -dow - 7); return { from: iso(m0), to: iso(addDays(m0, 6)), label: 'la semaine dernière' }; }
    if (/\bmois dernier\b/.test(t)){ var a = new Date(today.getFullYear(), today.getMonth() - 1, 1), b = new Date(today.getFullYear(), today.getMonth(), 0); return { from: iso(a), to: iso(b), label: 'le mois dernier' }; }
    if (/\b(ce mois|du mois|mois en cours|ce mois-ci)\b/.test(t)) return { from: iso(new Date(today.getFullYear(), today.getMonth(), 1)), to: iso(today), label: 'ce mois-ci' };
    if (/\b(cette annee|de l annee|annee en cours)\b/.test(t)) return { from: iso(new Date(today.getFullYear(), 0, 1)), to: iso(today), label: 'cette année' };
    if (/\b(aujourd hui|ce jour)\b/.test(t)) return { from: iso(today), to: iso(today), label: "aujourd'hui" };
    if (/\bhier\b/.test(t)) return { from: iso(addDays(today, -1)), to: iso(addDays(today, -1)), label: 'hier' };
    return { from: iso(addDays(today, -dow)), to: iso(today), label: 'cette semaine' };
  }

  // Actions connues mais pas encore disponibles dans EVA (registre « à développer »).
  var NOT_YET = [
    ['service_create', /\b(ajoute|ajouter|cree|creer|nouvelle)\w*\b.*\bprestations?\b/],
    ['client_create', /\b(cree|creer|ajoute|ajouter|enregistre)\w*\b.*\b(nouveau |nouvelle )?(client|cliente)\b|\bnouveau client\b/],
    ['quote_send', /\benvo(ie|yer|ies)\b.*\bdevis\b/],
    ['booking_cancel', /\b(annule|annuler|refuse|refuser)\b.*\b(rendez|rdv|intervention|demande)/],
    ['booking_create', /\b(prends?|prendre|cree|creer|planifie|planifier|ajoute)\b.*\b(rendez-vous|rendez vous|rdv)\b/]
  ];

  function parseDuration(t){
    var m;
    if ((m = /\b(\d{1,2})\s?h(?:eures?)?\s?(\d{2})?\b/.exec(t))) return Number(m[1]) * 60 + (m[2] ? Number(m[2]) : 0);
    if ((m = /\b(\d{2,3})\s?(?:min|minutes)\b/.exec(t))) return Number(m[1]);
    return null;
  }

  // Nom de client : « de/pour/chez Monsieur Dupont », « client Dupont ».
  function parseClient(raw){
    var m = /\b(?:de|pour|chez|du client|client|cliente)\s+((?:monsieur|madame|mademoiselle|m\.|mme|mr)\s+[A-Za-zÀ-ÿ'’-]+(?:\s+[A-Z][A-Za-zÀ-ÿ'’-]+)?)/i.exec(raw)
         || /\b((?:monsieur|madame|mademoiselle|mme)\s+[A-Za-zÀ-ÿ'’-]+(?:\s+[A-Z][A-Za-zÀ-ÿ'’-]+)?)/i.exec(raw)
         || /\b(?:client|cliente|chez)\s+([A-Z][A-Za-zÀ-ÿ'’-]+(?:\s+[A-Z][A-Za-zÀ-ÿ'’-]+)?)/.exec(raw);
    return m ? m[1].replace(/\s+/g, ' ').trim() : null;
  }

  // Prestation demandée dans « prépare un devis pour le remplacement du mitigeur de Monsieur Dupont ».
  function parseService(raw, client){
    var s = raw.replace(/^.*?\b(?:devis|chiffrage|chiffre|chiffrer)\b\s*(?:pour|de|d'|d’)?\s*/i, '');
    if (client) s = s.replace(new RegExp('\\s*(?:de|pour|chez|du client|client)?\\s*' + client.replace(/[.*+?^${}()|[\]\\]/g, '\\$&') + '.*$', 'i'), '');
    s = s.replace(/\b(?:et|puis)\b.*$/i, '').replace(/^(?:le|la|les|un|une|l'|l’)\s+/i, '').trim();
    return s || null;
  }

  var PREFIX = /^(?:(?:hey|ok|dis|bonjour|salut)\s+)?(?:eva|hayeva)\b[\s,:-]*/;
  var POLITE = /\b(?:s il te plait|s il vous plait|stp|svp|merci)\b/g;

  function parseOne(raw, now){
    var t = norm(raw).replace(PREFIX, '').replace(POLITE, '').trim();
    var when = parseWhen(t, now);
    var today = iso(startOfDay(now));
    if (!t) return { intent: 'empty' };

    if (/\b(que sais[- ]tu faire|que peux[- ]tu faire|tes capacites|qu est-ce que tu (sais|peux) faire|^aide$)/.test(t)) return { intent: 'capabilities', args: {}, label: 'Ce que je sais faire' };
    if (/\b(fonctionnalite|evolution|amelioration)s?\b/.test(t) && /\b(ajoute|ajouter|cree|creer|developpe|voudrais|veux|nouvelle|propose)\w*\b/.test(t)){
      return { intent: 'dev_request', args: { text: raw.replace(/^\s*(?:(?:hey|ok|dis|bonjour|salut)\s+)?(?:eva|hayeva)\b\s*[,:-]?\s*/i, '').trim() }, label: 'Demande d’évolution' };
    }
    if (/\b(facture|facturer|preparer? (une|la) facture)\b.*\bderniere intervention\b|\bderniere intervention\b.*\bfactur/.test(t)) return { intent: 'invoice_last', args: {}, label: 'Facture de la dernière intervention' };
    if (/\b(decale|decaler|deplace|deplacer|reporte|reporter|bouge|bouger|avance|avancer|change|changer)\b.*\b(rendez|rdv|intervention)/.test(t)){
      var which = /\bdernier\b/.test(t) ? 'last' : (/\b(deuxieme|second)\b/.test(t) ? 1 : 0);
      return { intent: 'move_booking', args: { date: (when && (when.date || when.from)) || today, which: which, client: parseClient(raw) }, label: 'Déplacer un rendez-vous' };
    }
    for (var i = 0; i < NOT_YET.length; i++) if (NOT_YET[i][1].test(t) && !/\bfiche\b|\btrouve|\bcherche/.test(t)) return { intent: 'not_yet', args: { tool: NOT_YET[i][0] }, label: 'Action à venir' };
    if (/\bcombien\b.*\b(factur|encaiss|gagne|chiffre)|\bchiffre d affaires\b|\b(j ai|ai-je) (facture|encaisse)\b|\bencaissements?\b|\brecettes?\b/.test(t)){
      var per = parsePeriod(t, now);
      return { intent: 'finance', args: { from: per.from, to: per.to }, label: 'Finances (' + per.label + ')' };
    }
    if (/\battend\w*\b.*\breponse\b|\ben attente de reponse\b|\bdemandes? de (rendez|rdv)|\bqui attend\b|\ba rappeler\b|\brappels?\b/.test(t)) return { intent: 'awaiting', args: {}, label: 'Clients en attente de réponse' };
    if (/\bdevis\b/.test(t) && /\b(retrouve|retrouver|dernier|derniers|les devis de|devis de|devis du|devis pour)\b/.test(t) && parseClient(raw) && !/\b(prepare|fais|etablis|redige|cree|chiffre)\w*\b/.test(t)){
      return { intent: 'client_quotes', args: { client: parseClient(raw) }, label: 'Devis du client' };
    }
    if (/\b(prepare|resume|organise|planifie|recapitule|recap)\w*\b.*\b(journee|journee de travail|programme)\b|\bma journee\b|\bmon programme\b/.test(t)){
      return { intent: 'brief', args: { date: (when && when.date) || today }, label: 'Ma journée' + (when ? ' (' + when.label + ')' : '') };
    }
    if (/\bconflit|\bchevauch|\bdoublon/.test(t)){
      var c = when && when.from ? when : { from: today, to: iso(addDays(startOfDay(now), 14)) };
      return { intent: 'conflicts', args: { from: c.from || c.date, to: c.to || c.date }, label: 'Conflits de planning' };
    }
    if (/\bdisponib|\bdispo\b|\bcreneaux?\b|\bquand (suis|serai|je suis)|\blibre\b/.test(t)){
      var p = when ? (when.from ? when : { from: when.date, to: when.date }) : { from: today, to: iso(addDays(startOfDay(now), 6)) };
      return { intent: 'free_slots', args: { from: p.from, to: p.to, duration: parseDuration(t) || 60 }, label: 'Créneaux libres' + (when ? ' (' + when.label + ')' : '') };
    }
    if (/\b(prepare|fais|fait|etablis|redige|cree)\w*\b.*\b(devis|chiffrage)\b|\bchiffr(e|er)\b|\bdevis pour\b/.test(t) && !/\bdevis en attente\b|\bmes devis\b/.test(t)){
      var client = parseClient(raw);
      return { intent: 'quote_estimate', args: { client: client, service: parseService(raw, client) || '' }, label: 'Préparer un devis' };
    }
    if (/\bdevis\b/.test(t)) return { intent: 'quotes_pending', args: {}, label: 'Devis à traiter' };
    if (/\bfactur|\breglement|\bimpaye|\bpaiement/.test(t)) return { intent: 'invoices_todo', args: {}, label: 'Factures à préparer' };
    if (/\battention\b|\banomalie|\burgen|\bpriorit|\bdossiers?\b|\ba traiter\b|\bproblemes?\b|\balertes?\b/.test(t)) return { intent: 'attention', args: {}, label: 'Points d’attention' };
    if (/\b(cherche|trouve|recherche|fiche|coordonnees|numero|telephone|adresse)\b/.test(t) || /^client\b/.test(t)){
      var q = parseClient(raw) || raw.replace(/^.*?\b(?:cherche|trouve|recherche|fiche|coordonnees|numero|telephone|adresse)\b\s*(?:de|du|le|la|client|cliente)?\s*/i, '').trim();
      return { intent: 'find_client', args: { query: q.replace(/^(?:client|cliente)\s+/i, '') }, label: 'Recherche de client' };
    }
    if (/\bintervention|\brendez|\brdv\b|\bplanning\b|\bagenda\b|\bprogramme\b|\bmontre\b|\bqu ai-je\b|\bqu est-ce que j ai\b/.test(t) || when){
      return { intent: 'agenda', args: { date: (when && (when.date || when.from)) || today }, label: 'Interventions' + (when ? ' (' + when.label + ')' : " (aujourd'hui)") };
    }
    return { intent: 'unknown', label: 'Commande non reconnue' };
  }

  // Demandes composées : « … et regarde mes disponibilités la semaine prochaine ».
  function parse(raw, now){
    now = now || new Date();
    var text = String(raw || '').slice(0, 300).replace(/^\s*(?:(?:hey|ok|dis|bonjour|salut)\s+)?(?:eva|hayeva)\b\s*[,:-]?\s*/i, '');
    var parts = text.split(/\s*(?:,|\bet\b|\bpuis\b|\bensuite\b)\s+(?=(?:regarde|montre|verifie|vérifie|prepare|prépare|cherche|trouve|donne|affiche|dis|liste|quels|quelles|quelle|quel|resume|résume)\b)/i)
      .map(function(s){ return s.trim(); }).filter(Boolean);
    var out = parts.map(function(p){ var r = parseOne(p, now); r.text = p; return r; })
      .filter(function(r){ return r.intent !== 'empty'; });
    return out.length ? out : [{ intent: 'empty', text: text }];
  }

  var SUGGESTIONS = [
    'Montre-moi mes interventions de demain',
    'Quels clients attendent une réponse ?',
    'Combien j’ai facturé cette semaine ?',
    'Prépare ma journée de demain',
    'Quels dossiers nécessitent mon attention ?',
    'Vérifie les conflits de planning',
    'Prépare les factures des interventions terminées',
    'Prépare mes devis en attente',
    'Mes disponibilités la semaine prochaine'
  ];

  return { parse: parse, parseWhen: parseWhen, parsePeriod: parsePeriod, norm: norm, iso: iso, SUGGESTIONS: SUGGESTIONS };
});
