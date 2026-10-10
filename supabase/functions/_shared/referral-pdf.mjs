// Justificatifs de parrainage HAYEVA — mise en page PDF (A4).
// Module sans dépendance d'environnement : la fonction serveur (Deno) et les
// tests locaux (Node) lui passent pdf-lib et qrcode-generator. Il ne fait que
// mettre en page le contenu FIGÉ renvoyé par issue_referral_document() :
// aucun montant, statut ou date n'est calculé ici.

const NAVY = [16, 26, 43], INK = [23, 34, 52], INK2 = [74, 85, 104], COPPER = [215, 161, 107], COPPER_INK = [138, 90, 43];
const IVORY = [247, 245, 241], IVORY2 = [239, 235, 228], LINE = [226, 220, 210], RED = [155, 44, 28];

const TITLES = {
  ATTESTATION: 'Attestation de recommandation',
  RELEVE: 'Relevé de récompense',
  JUSTIFICATIF: 'Justificatif de règlement',
};

export function fmtDate(iso, long = true) {
  if (!iso) return '—';
  const d = new Date(String(iso).length === 10 ? iso + 'T12:00:00Z' : iso);
  return d.toLocaleDateString('fr-FR', long ? { timeZone: 'Europe/Paris', day: 'numeric', month: 'long', year: 'numeric' }
    : { timeZone: 'Europe/Paris', day: '2-digit', month: '2-digit', year: 'numeric' });
}
export function fmtEuros(cents) {
  const n = (Number(cents) || 0) / 100;
  const [i, f] = n.toFixed(2).split('.');
  return i.replace(/\B(?=(\d{3})+(?!\d))/g, ' ') + ',' + f + ' €';
}

export async function buildReferralPdf(lib, qrcode, doc, logoPng, opts = {}) {
  const { PDFDocument, StandardFonts, rgb } = lib;
  const c = (a) => rgb(a[0] / 255, a[1] / 255, a[2] / 255);
  const pdf = await PDFDocument.create();
  const title = TITLES[doc.kind] || 'Document';
  pdf.setTitle(title + ' ' + doc.number);
  pdf.setAuthor('HAYEVA');
  pdf.setSubject('Programme de parrainage HAYEVA');
  pdf.setCreator('HAYEVA');
  pdf.setProducer('HAYEVA');
  const page = pdf.addPage([595.28, 841.89]);
  const W = page.getWidth(), H = page.getHeight(), M = 48;
  const reg = await pdf.embedFont(StandardFonts.Helvetica);
  const bold = await pdf.embedFont(StandardFonts.HelveticaBold);
  const logo = logoPng ? await pdf.embedPng(logoPng) : null;
  const k = doc.content || {};

  // Texte limité à l'encodage des polices standard (accents français, €, « »).
  const safe = (s) => {
    const t = String(s == null ? '' : s).replace(/[   ]/g, ' ').replace(/[‐-‒]/g, '-');
    let out = '';
    for (const ch of t) { try { reg.encodeText(ch); out += ch; } catch { out += '?'; } }
    return out;
  };
  const text = (s, x, y, size = 10, font = reg, color = INK) => page.drawText(safe(s), { x, y, size, font, color: c(color) });
  const width = (s, size, font = reg) => font.widthOfTextAtSize(safe(s), size);
  const wrap = (s, size, maxW, font = reg) => {
    const words = safe(s).split(/\s+/); const lines = []; let cur = '';
    for (const w of words) { const t = cur ? cur + ' ' + w : w; if (font.widthOfTextAtSize(t, size) > maxW && cur) { lines.push(cur); cur = w; } else cur = t; }
    if (cur) lines.push(cur); return lines;
  };
  const para = (s, x, y, size, maxW, font = reg, color = INK, lead = 1.45) => {
    const ls = wrap(s, size, maxW, font); ls.forEach((l, i) => text(l, x, y - i * size * lead, size, font, color)); return y - ls.length * size * lead;
  };

  // En-tête ivoire : logo officiel tel quel (aucun filtre, aucun fond ajouté).
  page.drawRectangle({ x: 0, y: H - 118, width: W, height: 118, color: c(IVORY) });
  if (logo) { const lh = 58, lw = lh * logo.width / logo.height; page.drawImage(logo, { x: M, y: H - 30 - lh, width: lw, height: lh }); }
  const tTitle = title.toUpperCase();
  text(tTitle, W - M - width(tTitle, 13.5, bold), H - 50, 13.5, bold, NAVY);
  const tNo = 'N° ' + doc.number;
  text(tNo, W - M - width(tNo, 10.5, bold), H - 68, 10.5, bold, COPPER_INK);
  const tDate = 'Édité le ' + fmtDate(doc.issued_at);
  text(tDate, W - M - width(tDate, 9.5), H - 84, 9.5, reg, INK2);
  page.drawRectangle({ x: 0, y: H - 121, width: W, height: 3, color: c(COPPER) });

  let y = H - 160;
  const section = (label) => { text(label.toUpperCase(), M, y, 8.5, bold, COPPER_INK); y -= 8; page.drawLine({ start: { x: M, y }, end: { x: W - M, y }, thickness: 0.6, color: c(LINE) }); y -= 18; };
  const row = (label, value, strong = false) => {
    text(label, M, y, 10, reg, INK2);
    const ls = wrap(value, 10.5, W - 2 * M - 190, strong ? bold : reg);
    ls.forEach((l, i) => text(l, M + 190, y - i * 15, 10.5, strong ? bold : reg, INK));
    y -= Math.max(1, ls.length) * 15 + 6;
  };
  const partyBlock = (heading, p, x, w, y0) => {
    let yy = y0; text(heading.toUpperCase(), x, yy, 8.5, bold, COPPER_INK); yy -= 16;
    const lines = [];
    if (p) {
      if (p.legal_name) lines.push([p.legal_name, true]);
      if (p.name) lines.push([p.name, !p.legal_name]);
      if (p.trade_name && !p.legal_name) lines.push([p.trade_name, true]);
      if (p.legal_form) lines.push([p.legal_form, false]);
      if (p.address) lines.push([p.address, false]);
      if (p.siret) lines.push(['SIRET : ' + p.siret, false]);
      if (p.rcs) lines.push([p.rcs, false]);
      if (p.vat_number) lines.push(['TVA : ' + p.vat_number, false]);
      if (p.email) lines.push([p.email, false]);
      if (p.website) lines.push([p.website.replace(/^https?:\/\//, ''), false]);
    }
    for (const [l, b] of lines) { for (const s of wrap(l, 10, w, b ? bold : reg)) { text(s, x, yy, 10, b ? bold : reg, INK); yy -= 14; } }
    return yy;
  };
  const notice = (s) => {
    const ls = wrap(s, 10, W - 2 * M - 34, bold); const h = ls.length * 14.5 + 16;
    page.drawRectangle({ x: M, y: y - h + 12, width: W - 2 * M, height: h, color: c(IVORY) });
    page.drawRectangle({ x: M, y: y - h + 12, width: 3, height: h, color: c(COPPER) });
    ls.forEach((l, i) => text(l, M + 18, y - 4 - i * 14.5, 10, bold, NAVY));
    y -= h + 14;
  };

  if (doc.kind === 'ATTESTATION') {
    const b = k.beneficiary || {};
    section(b.type === 'business' ? 'Apporteur d\'affaires' : 'Parrain ou marraine');
    row('Identité', [b.legal_name, b.name].filter(Boolean).join(' — ') || '—', true);
    if (b.siret) row('SIRET', b.siret);
    y -= 6; section('Recommandation');
    row('Référence', k.referral_reference, true);
    row('Date d\'enregistrement', fmtDate(k.registered_at));
    row('Code utilisé', k.code_used);
    row('Statut au ' + fmtDate(doc.issued_at), k.status_label, true);
    y -= 6; section('Étapes confirmées');
    for (const st of (k.steps || [])) {
      const dot = st.stop ? RED : COPPER;
      page.drawCircle({ x: M + 4, y: y + 3.5, size: 3.2, color: c(dot) });
      text(st.label, M + 16, y, 10.5, st.stop ? bold : reg, st.stop ? RED : INK);
      const d = fmtDate(st.at); text(d, W - M - width(d, 10), y, 10, reg, INK2);
      y -= 18;
    }
    y -= 8; notice(k.notice || '');
  } else {
    const top = y;
    const yl = partyBlock('Émetteur', k.company, M, (W - 2 * M) / 2 - 16, top);
    const yr = partyBlock('Bénéficiaire', k.beneficiary, M + (W - 2 * M) / 2 + 8, (W - 2 * M) / 2 - 8, top);
    y = Math.min(yl, yr) - 14;
    if (doc.kind === 'RELEVE') {
      section(k.is_business ? 'Commission d\'apport d\'affaires' : 'Récompense de parrainage');
      row('Référence de la recommandation', k.referral_reference, true);
      row('Date de validation', fmtDate(k.validated_at));
      row('Montant de la récompense', fmtEuros(k.amount_cents), true);
      row('Statut', k.settlement === 'REGLE' ? 'Réglé le ' + fmtDate(k.payment_date) + (k.payout_reference ? ' (' + k.payout_reference + ')' : '') : 'À régler', true);
      y -= 6; section('Conditions de validation');
      for (const s of (k.conditions || [])) {
        page.drawRectangle({ x: M + 1, y: y + 2, width: 5, height: 5, color: c(COPPER) });
        y = para(s, M + 16, y, 10, W - 2 * M - 16) - 6;
      }
      y -= 6; notice(k.notice || '');
    } else {
      section('Règlement');
      row('Référence du règlement', k.payout_reference, true);
      row('Date du règlement', fmtDate(k.payment_date));
      row('Montant réglé', fmtEuros(k.amount_cents), true);
      row('Moyen de règlement', k.method);
      y -= 6; section('Récompenses concernées');
      for (const r of (k.rewards || [])) {
        text(r.reference, M, y, 10.5, reg, INK); const a = fmtEuros(r.amount_cents); text(a, W - M - width(a, 10.5, bold), y, 10.5, bold, INK);
        y -= 8; page.drawLine({ start: { x: M, y }, end: { x: W - M, y }, thickness: 0.4, color: c(LINE) }); y -= 14;
      }
      y -= 6; notice(k.notice || '');
    }
  }

  // Pied de page : vérification (QR + code) et mentions disponibles.
  const fy = 46, fh = 92;
  page.drawRectangle({ x: M, y: fy, width: W - 2 * M, height: fh, color: c(IVORY2) });
  const url = (opts.verifyBaseUrl || 'https://hayeva.fr/verification') + '?c=' + encodeURIComponent(doc.verification_code || '');
  if (qrcode && doc.verification_code) {
    const q = qrcode(0, 'M'); q.addData(url); q.make();
    const n = q.getModuleCount(), size = 72, cell = size / n, qx = M + 10, qy = fy + 10;
    page.drawRectangle({ x: qx - 3, y: qy - 3, width: size + 6, height: size + 6, color: c([255, 255, 255]) });
    for (let r = 0; r < n; r++) for (let col = 0; col < n; col++) if (q.isDark(r, col)) page.drawRectangle({ x: qx + col * cell, y: qy + size - (r + 1) * cell, width: cell + 0.05, height: cell + 0.05, color: c(NAVY) });
  }
  const vx = M + 98;
  text('Vérifier ce document', vx, fy + fh - 22, 10.5, bold, NAVY);
  text('Code : ' + (doc.verification_code || '—'), vx, fy + fh - 38, 10, bold, COPPER_INK);
  text(url.replace(/^https?:\/\//, ''), vx, fy + fh - 52, 8.5, reg, INK2);
  para('Document établi par HAYEVA à partir des données enregistrées dans son système. Seule la version consultable avec ce code fait foi.', vx, fy + fh - 66, 8, W - 2 * M - 108, reg, INK2, 1.35);
  const co = k.company || {};
  const legal = [co.legal_name || co.trade_name || 'HAYEVA', co.address, co.siret ? 'SIRET ' + co.siret : null].filter(Boolean).join(' · ');
  text(legal + (co.siret ? '' : ' · Mentions légales : hayeva.fr/#legal/mentions'), M, 28, 7.5, reg, INK2);
  const pg = 'Page 1 / 1'; text(pg, W - M - width(pg, 7.5), 28, 7.5, reg, INK2);

  if (opts.specimen) {
    const s = 'SPÉCIMEN — DONNÉES D\'EXEMPLE';
    page.drawText(safe(s), { x: 118, y: 270, size: 31, font: bold, color: c(COPPER), opacity: 0.16, rotate: lib.degrees(32) });
  }
  return await pdf.save({ useObjectStreams: true });
}
