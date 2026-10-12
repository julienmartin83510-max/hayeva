// EVA — interprète de commandes en français (déterministe, sans IA).
// Traduit une phrase en une ou plusieurs intentions d'une liste FERMÉE
// (lectures : agenda, fiche client, catalogue, factures, statistiques… ;
// actions : toujours une PROPOSITION à confirmer). Le serveur (eva_run,
// eva_query, eva_propose) revérifie tout : cet interprète ne donne aucun droit, il choisit seulement
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

  // Heure citée : « à 10 h », « à 14h30 », « 9 heures ».
  function parseTime(t){
    var m = /\b(?:a|vers|pour)\s+(\d{1,2})\s?(?:h|heures?)\s?(\d{2})?\b/.exec(t) || /\b(\d{1,2})\s?h\s?(\d{2})\b/.exec(t) || /\b(\d{1,2})\s?h\b(?!\s*de\s)/.exec(t);
    if (!m) return null;
    var h = Number(m[1]), mi = m[2] ? Number(m[2]) : 0;
    return h < 24 && mi < 60 ? String(h).padStart(2, '0') + ':' + String(mi).padStart(2, '0') : null;
  }
  // Semaine complète (lundi → samedi) pour « cette semaine » / « la semaine prochaine ».
  // ahead : pour le planning, « cette semaine » dit un dimanche désigne la semaine qui commence.
  function weekRange(t, now, ahead){
    var today = startOfDay(now), dow = (today.getDay() + 6) % 7, mon = addDays(today, -dow);
    if (ahead && dow === 6) mon = addDays(mon, 7);
    if (/\bsemaine prochaine\b/.test(t)) mon = addDays(mon, 7);
    else if (/\bsemaine derniere\b/.test(t)) mon = addDays(mon, -7);
    else if (/\b(ce mois|du mois|mois en cours)\b/.test(t)) return { from: iso(new Date(today.getFullYear(), today.getMonth(), 1)), to: iso(new Date(today.getFullYear(), today.getMonth() + 1, 0)), label: 'ce mois-ci' };
    else if (/\bmois prochain\b/.test(t)) return { from: iso(new Date(today.getFullYear(), today.getMonth() + 1, 1)), to: iso(new Date(today.getFullYear(), today.getMonth() + 2, 0)), label: 'le mois prochain' };
    return { from: iso(mon), to: iso(addDays(mon, 5)), label: /\bsemaine prochaine\b/.test(t) ? 'la semaine prochaine' : (/\bsemaine derniere\b/.test(t) ? 'la semaine dernière' : 'cette semaine') };
  }
  // « ce client », « chez lui », « sa fiche » : client de la conversation en cours.
  var CTX = /\b(ce client|cette cliente|ce meme client|chez lui|chez elle|sa fiche|son historique|ses equipements|son dernier|sa derniere|ce monsieur|cette dame)\b/;
  function clientOrCtx(raw, t){ return parseClient(raw) || (CTX.test(t) ? '@ctx' : null); }
  function afterWord(raw, words){
    var m = new RegExp('\\b(?:' + words + ')\\b\\s*(?:de |d\'|d’|du |des |pour |:)?\\s*(.*)$', 'i').exec(raw);
    return m ? m[1].replace(/[.?!]+$/, '').trim() : '';
  }
  function parseContact(raw){
    var email = (/[^\s@]+@[^\s@]+\.[^\s@]+/.exec(raw) || [])[0] || '';
    var phone = ((/(?:\+33\s?|0)[1-9](?:[\s.-]?\d{2}){4}/.exec(raw) || [])[0] || '').replace(/[\s.-]/g, '');
    return { email: email.replace(/[.,;]+$/, ''), phone: phone };
  }

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
    if (!m) return null;
    // Le second mot n'est gardé que s'il commence par une majuscule (prénom ou nom composé),
    // pour ne pas avaler « demain », « jeudi »… : « Monsieur Martin demain » → « Monsieur Martin ».
    var w = m[1].replace(/\s+/g, ' ').trim().split(' ');
    if (w.length === 3 && !/^[A-ZÀ-Ý]/.test(w[2])) w.pop();
    if (w.length === 2 && /^(?:monsieur|madame|mademoiselle|m\.|mme|mr)$/i.test(w[0]) === false && !/^[A-ZÀ-Ý]/.test(w[1])) w.pop();
    return w.join(' ');
  }

  // Prestation demandée dans « prépare un devis pour le remplacement du mitigeur de Monsieur Dupont ».
  function parseService(raw, client){
    var s = raw.replace(/^.*?\b(?:devis|chiffrage|chiffre|chiffrer)\b\s*(?:pour|de|d'|d’)?\s*/i, '');
    if (client) s = s.replace(new RegExp('\\s*(?:de|pour|chez|du client|client)?\\s*' + client.replace(/[.*+?^${}()|[\]\\]/g, '\\$&') + '.*$', 'i'), '');
    s = s.replace(/\b(?:et|puis)\b.*$/i, '').replace(/^(?:le|la|les|un|une|l'|l’)\s+/i, '').replace(/^[\s.,;:!?…-]+|[\s.,;:!?…-]+$/g, '').trim();
    return s.length > 1 ? s : null;
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
      // Nouvelle date visée : « … à jeudi 14 h », « … au 15/01 à 9 h », « … pour demain 10 h ».
      var mt = new RegExp('\\s(?:a|au|pour|vers)\\s+(?=(?:' + DAYS.join('|') + '|demain|apres-demain|le \\d|\\d{1,2}\\/|\\d{1,2} (?:' + MONTHS.join('|') + ')))').exec(t);
      var before = mt ? t.slice(0, mt.index) : t, after = mt ? t.slice(mt.index) : '';
      var wFrom = parseWhen(before, now), wTo = after ? parseWhen(after, now) : null;
      var mv = { date: (wFrom && (wFrom.date || wFrom.from)) || (!mt && when && (when.date || when.from)) || today, which: which, client: parseClient(raw) };
      if (wFrom && (wFrom.date || wFrom.from)) mv.from_date = wFrom.date || wFrom.from;
      if (wTo && wTo.date){ mv.to_date = wTo.date; mv.to_time = parseTime(after.replace(/^\s*(?:a|au|pour|vers)\s+/, ' ')) || ''; }
      return { intent: 'move_booking', args: mv, label: 'Déplacer un rendez-vous' };
    }
    // Confirmer une demande de rendez-vous précise (jamais une simple phrase « je confirme »).
    if (/\b(confirme|confirmer|accepte|accepter|valide|valider)\b/.test(t) && /\b(demande|rendez|rdv|reservation)/.test(t) && !/\b(tous|toutes)\b/.test(t)){
      var cc = clientOrCtx(raw, t);
      return cc ? { intent: 'booking_confirm', args: { client: cc }, label: 'Confirmer une demande de rendez-vous' } : { intent: 'awaiting', args: {}, label: 'Demandes à confirmer' };
    }
    // Horaires de travail / disponibilité : réglage dans EVA (jamais deviné par la voix).
    if (/\bhoraires?\b|\bheures? d ouverture\b/.test(t) && /\b(change|changer|modifie|modifier|mets? a jour|regle|regler|ajuste|ajuster|definis|definir)\b/.test(t)) return { intent: 'work_hours', args: {}, label: 'Horaires de travail' };
    if (/\b(mes |les )?horaires?\b/.test(t) && /\b(quels?|quelles?|affiche|montre|donne)\b/.test(t) && !/\brendez|\brdv\b/.test(t)) return { intent: 'work_hours', args: { view: true }, label: 'Horaires de travail' };
    // Réservations / demandes en attente de confirmation.
    if (/\b(reservations?|demandes?|rendez-vous|rendez vous|rdv)\b.*\b(en attente|a confirmer|non confirme)/.test(t) && !/\bdevis\b/.test(t)) return { intent: 'awaiting', args: {}, label: 'Réservations en attente' };
    // Dernière facture.
    if (/\b(derniere|dernieres) factures?\b|\bfacture la plus recente\b/.test(t)) return { intent: 'invoices_list', args: { client: clientOrCtx(raw, t), last: true }, label: 'Dernière facture' };
    // ---------- Phase 2 : actions et lectures étendues ----------
    // Garde-fous : EVA ne supprime rien et ne traite jamais une action « en masse ».
    var ACT = /\b(envoie|envoyer|envoies|annule|annuler|refuse|refuser|supprime|supprimer|efface|effacer|credite|crediter|debite|debiter|modifie|modifier|confirme|confirmer|valide|valider|emets|emettre|facture|facturer)\b/;
    if (ACT.test(t) && /\b(tous|toutes) (les|mes|ces)\b|\ben masse\b|\bchaque (client|devis|facture|rendez)/.test(t)) return { intent: 'bulk_refused', args: {}, label: 'Action groupée refusée' };
    if (/\b(supprime|supprimer|efface|effacer|detruis|detruire|vide|vider)\b/.test(t)) return { intent: 'delete_refused', args: {}, label: 'Suppression non disponible' };
    if (/\bcompte[- ]?rendu\b|\brapport d intervention\b/.test(t)) return { intent: 'report', args: { client: clientOrCtx(raw, t) }, label: 'Compte rendu d’intervention' };
    if (/\b(suspend|suspends|suspendre|desactive|desactiver|bloque)\b.*\bparrain/.test(t)) return { intent: 'referrer_admin', args: { client: clientOrCtx(raw, t), status: 'suspended' }, label: 'Suspendre un parrain' };
    if (/\b(reactive|reactiver|active|activer|debloque)\b.*\bparrain/.test(t)) return { intent: 'referrer_admin', args: { client: clientOrCtx(raw, t), status: 'active' }, label: 'Réactiver un parrain' };
    if (/\bcode (de )?parrainage\b/.test(t) && /\b(change|changer|modifie|modifier|remplace)\b/.test(t)){
      var cm = /\ben\s+([a-z0-9]{6,12})\b/.exec(t);
      return { intent: 'referrer_admin', args: { client: clientOrCtx(raw, t), code: cm ? cm[1].toUpperCase() : '' }, label: 'Changer un code de parrainage' };
    }
    var amt = /(\d+(?:[.,]\d{1,2})?)\s?(?:€|eur\b|euros?\b)/i.exec(raw);
    if (amt && /\b(credite|crediter|ajoute|ajouter|offre|offrir|debite|debiter|retire|retirer)\b/.test(t) && /\b(fidelite|credit|cagnotte|avoir|geste)\b|\ba (monsieur|madame)\b/.test(t)){
      var neg = /\b(debite|debiter|retire|retirer)\b/.test(t);
      return { intent: 'wallet_adjust', args: { client: clientOrCtx(raw, t), amount: (neg ? -1 : 1) * Number(amt[1].replace(',', '.')) }, label: 'Crédit fidélité' };
    }
    if (/\bfidelite\b|\bcagnotte\b|\bcredit (de |du )?client\b|\bportefeuille\b/.test(t)) return { intent: 'loyalty', args: { client: clientOrCtx(raw, t) }, label: 'Fidélité' };
    if (/\bparrains?\b|\bparrainages?\b|\bcodes? (de )?parrainage\b|\bambassadeurs?\b/.test(t)) return { intent: 'referrals', args: { query: (parseClient(raw) || '').replace(/^(monsieur|madame|mme|m\.)\s+/i, '') }, label: 'Parrainage' };
    if (/\bentretiens?\b.*\b(renouveler|prevoir|a faire|echeance|echus?|en retard|arrive|depasse)|\ba renouveler\b|\bentretiens? annuels?\b/.test(t)) return { intent: 'maintenance_due', args: { days: /\bmois prochain|\b60\b/.test(t) ? 60 : 45 }, label: 'Entretiens à renouveler' };
    if (/\bstatisti|\bstats\b|\btaux de/.test(t)){ var sp = /\bannee\b/.test(t) ? parsePeriod(t, now) : weekRange(/\bmois\b/.test(t) ? 'ce mois' : t, now); return { intent: 'stats', args: { from: sp.from, to: sp.to }, label: 'Statistiques (' + sp.label + ')' }; }
    if (/\bcombien de (rendez|rdv|interventions?|chantiers?)\b|\b(rendez-vous|rendez vous|rdv|interventions|planning|agenda)\b.*\b(de la |cette |la |du )?(semaine|mois)\b/.test(t) && !/\b(prends?|cree|planifie|annule|decale|deplace)\b/.test(t)){
      var wr = weekRange(t, now, true);
      return { intent: 'agenda_range', args: { from: wr.from, to: wr.to }, label: 'Rendez-vous (' + wr.label + ')' };
    }
    if (/\b(ajoute|ajouter|cree|creer|nouvelle)\w*\b.*\bprestations?\b/.test(t)) return { intent: 'service_create', args: { name: afterWord(raw, 'prestation') }, label: 'Ajouter une prestation' };
    if (/\btarifs?\b|\bprix\b|\bcombien coute|\bcombien ca coute|\bcatalogue\b|\bquelles? prestations\b/.test(t) && !/\bdevis\b/.test(t)){
      return { intent: 'catalog', args: { query: norm(raw).replace(PREFIX, '').replace(/\b(quel|quelle|quels|est|le|la|les|du|de|d|un|une|des|mes|mon|ma|tarifs?|prix|combien|coute|ca|catalogue|prestations?|montre|affiche|moi|donne)\b/g, ' ').replace(/[?,.:\/-]+/g, ' ').replace(/\s+/g, ' ').trim() }, label: 'Catalogue et tarifs' };
    }
    if (/\b(cree|creer|ajoute|ajouter|enregistre|enregistrer|nouveau|nouvelle)\b.*\b(client|cliente)\b/.test(t) && !/\bfiche de\b|\btrouve|\bcherche|\brecherche/.test(t)){
      var nm = afterWord(raw, 'client|cliente').replace(/(?:\+33\s?|0)[1-9](?:[\s.-]?\d{2}){4}.*$/, '').replace(/[^\s@]+@[^\s@]+\.[^\s@]+.*$/, '').replace(/\b(?:au|a|tel|telephone|téléphone|mail|e-mail)\s*$/i, '').trim();
      var parts = nm.split(/\s+/).filter(Boolean), ct = parseContact(raw);
      return { intent: 'client_create', args: { first_name: parts.length > 1 ? parts[0] : '', last_name: parts.length > 1 ? parts.slice(1).join(' ') : (parts[0] || ''), phone: ct.phone, email: ct.email }, label: 'Nouveau client' };
    }
    if (/\b(modifie|modifier|change|changer|mets? a jour|mettre a jour|corrige|corriger)\b.*\b(telephone|numero|adresse|e-?mail|mail|ville|nom|prenom|fiche|code postal|notes?)\b/.test(t) && !/\bdevis\b|\brendez|\brdv\b|\bparrain/.test(t)){
      return { intent: 'client_update', args: { client: clientOrCtx(raw, t) }, label: 'Modifier une fiche client' };
    }
    if (/\b(annule|annuler|refuse|refuser)\b.*\b(rendez|rdv|intervention|demande)/.test(t)) return { intent: 'booking_cancel', args: { client: clientOrCtx(raw, t), date: when && (when.date || when.from) }, label: 'Annuler un rendez-vous' };
    if (/\b(prends?|prendre|cree|creer|planifie|planifier|ajoute|ajouter|programme|programmer|fixe|fixer|cale|caler|reserve|reserver)\b.*\b(rendez-vous|rendez vous|rdv|intervention)\b/.test(t)){
      var svc = (/\bpour (?:un |une |le |la |l )?((?!monsieur|madame|mme|m\.)[a-z][a-z\s'-]{3,})$/.exec(t.replace(/\b(demain|apres-demain|aujourd hui|lundi|mardi|mercredi|jeudi|vendredi|samedi|dimanche|a \d{1,2}\s?h\s?\d{0,2}|le \d{1,2}(\/\d{1,2})?|semaine prochaine)\b.*$/, '').trim()) || [])[1] || '';
      return { intent: 'booking_create', args: { client: clientOrCtx(raw, t), date: when && (when.date || when.from), time: parseTime(t), service: svc.trim() }, label: 'Nouveau rendez-vous' };
    }
    if (/\benvo(ie|yer|ies)\b.*\bdevis\b/.test(t)) return { intent: 'quote_send', args: { client: clientOrCtx(raw, t) }, label: 'Envoyer un devis' };
    if (/\b(modifie|modifier|change|changer|corrige|corriger|complete|completer|ajuste|ajuster)\b.*\bdevis\b/.test(t)) return { intent: 'quote_update', args: { client: clientOrCtx(raw, t) }, label: 'Modifier un devis' };
    if ((/\bfactures? (de|du|pour|chez)\b/.test(t) && clientOrCtx(raw, t)) || /\bpaiements? (recus?|encaisses?)\b|\bliste des (factures|paiements)\b|\bpaiements? de la (semaine|journee)|\bpaiements? du mois\b/.test(t)){
      var ir = /\b(semaine|mois|annee|aujourd hui|hier)\b/.test(t) ? parsePeriod(t, now) : null;
      return { intent: 'invoices_list', args: { client: clientOrCtx(raw, t), from: ir && ir.from, to: ir && ir.to }, label: 'Factures et paiements' };
    }
    if (/\b(fiche|historique|equipements?|derniere intervention|dernieres interventions|coordonnees|chaudiere|climatiseur|appareils?)\b/.test(t) && clientOrCtx(raw, t)){
      return { intent: 'client_detail', args: { client: clientOrCtx(raw, t), focus: /\bintervention/.test(t) ? 'interventions' : (/\bequipement|\bchaudiere|\bclimatiseur|\bappareil/.test(t) ? 'equipment' : '') }, label: 'Fiche client' };
    }
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
      var client = clientOrCtx(raw, t);
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
    'Montre-moi mes interventions d’aujourd’hui',
    'Combien de rendez-vous ai-je cette semaine ?',
    'Affiche les clients ayant un entretien à renouveler',
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
