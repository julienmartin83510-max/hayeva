// Contenu des e-mails du programme de parrainage (3 événements).
// Construit UNIQUEMENT à partir du contexte serveur referral_email_context() :
// données du parrain et du programme, jamais celles du client recommandé.
// Aucun montant n'est annoncé avant validation réelle de la récompense.

function esc(s) {
  return String(s == null ? '' : s).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
}
function euros(cents) {
  const [i, f] = ((Number(cents) || 0) / 100).toFixed(2).split('.');
  return i.replace(/\B(?=(\d{3})+(?!\d))/g, ' ') + ',' + f + ' €';
}
function date(iso) {
  if (!iso) return '—';
  const d = new Date(String(iso).length === 10 ? iso + 'T12:00:00Z' : iso);
  return d.toLocaleDateString('fr-FR', { timeZone: 'Europe/Paris', day: 'numeric', month: 'long', year: 'numeric' });
}
function row(label, value, strong) {
  return `<tr><td style="padding:8px 0;color:#5B6B78;width:46%;vertical-align:top;border-bottom:1px solid #EFE9DB;">${label}</td>` +
    `<td style="padding:8px 0;text-align:right;border-bottom:1px solid #EFE9DB;${strong ? 'font-weight:700;color:#101B24;' : ''}">${value}</td></tr>`;
}
function badge(label, tone) {
  const c = { pending: ['#FCEFD9', '#7A4E0C'], ok: ['#DFF3E6', '#17643F'] }[tone] || ['#EFEBE4', '#4A5568'];
  return `<table role="presentation" cellpadding="0" cellspacing="0" border="0" style="margin:0 0 18px;"><tr><td style="background-color:${c[0]};color:${c[1]};font-family:Arial,Helvetica,sans-serif;font-weight:700;font-size:13px;border-radius:999px;padding:7px 16px;">${label}</td></tr></table>`;
}
function button(href, label) {
  return `<p style="margin:24px 0 0;"><a href="${href}" style="display:inline-block;background:#D7A16B;color:#101A2B;text-decoration:none;padding:13px 26px;border-radius:999px;font-weight:700;font-size:15px;">${label}</a></p>` +
    `<p style="margin:10px 0 0;font-size:12px;color:#8A97A3;">Accès sécurisé : connexion à votre espace HAYEVA requise.</p>`;
}
const table = (rows) => `<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="border-collapse:collapse;font-size:14px;">${rows}</table>`;

// Renvoie null si l'événement ne correspond pas (ou plus) à la réalité :
// aucun e-mail n'est alors envoyé.
export function buildReferralEmail(ctx, site = 'https://hayeva.fr') {
  if (!ctx || !ctx.recipient_email) return null;
  const hello = `<h2 style="margin:0 0 6px;font-size:20px;color:#101B24;">Bonjour${ctx.first_name ? ' ' + esc(ctx.first_name) : ''},</h2>`;
  const link = button(`${site}/#espaceClient/parrainage`, 'Voir mon suivi');
  if (ctx.kind === 'new_referral') {
    if (!ctx.referral_reference) return null;
    const st = (ctx.status && ctx.status.label) || 'En cours';
    return {
      subject: `Recommandation enregistrée — ${ctx.referral_reference}`,
      reference: ctx.referral_reference,
      html: hello +
        `<p style="margin:0 0 18px;font-size:15px;">Une recommandation utilisant votre code${ctx.code ? ' <strong>' + esc(ctx.code) + '</strong>' : ''} vient d'être enregistrée auprès de HAYEVA.</p>` +
        badge('Recommandation enregistrée', 'pending') +
        table(row('Référence', esc(ctx.referral_reference), true) + row('Date d\'enregistrement', esc(date(ctx.registered_at))) + row('Statut actuel', esc(st))) +
        `<p style="margin:18px 0 0;font-size:13px;color:#4A5568;">La récompense n'est acquise qu'après la réalisation et le paiement d'une prestation éligible, puis sa validation par HAYEVA. Pour protéger la vie privée de la personne recommandée, aucune information la concernant n'est communiquée.</p>` +
        link,
    };
  }
  if (ctx.kind === 'reward_validated') {
    if (!ctx.reward_validated || !ctx.reward_cents) return null;
    return {
      subject: `Récompense validée — ${ctx.referral_reference}`,
      reference: ctx.referral_reference,
      html: hello +
        `<p style="margin:0 0 18px;font-size:15px;">Votre recommandation remplit les conditions du programme : la récompense est validée.</p>` +
        badge('Récompense validée — à régler', 'ok') +
        table(row('Référence', esc(ctx.referral_reference), true) + row('Date de validation', esc(date(ctx.validated_at))) + row('Montant', esc(euros(ctx.reward_cents)), true)) +
        `<p style="margin:18px 0 0;font-size:13px;color:#4A5568;">Montant fixé par le barème du programme. Votre relevé de récompense est disponible dans votre espace.</p>` +
        link,
    };
  }
  if (ctx.kind === 'payout_paid') {
    if (!ctx.payout_paid || !ctx.payout_reference) return null;
    const refs = (ctx.rewards || []).map(esc).join(', ');
    return {
      subject: `Règlement effectué — ${ctx.payout_reference}`,
      reference: ctx.payout_reference,
      html: hello +
        `<p style="margin:0 0 18px;font-size:15px;">HAYEVA a effectué le règlement de vos récompenses de parrainage.</p>` +
        badge('Règlement effectué', 'ok') +
        table(row('Référence du règlement', esc(ctx.payout_reference), true) + row('Date du règlement', esc(date(ctx.payment_date))) +
          row('Montant', esc(euros(ctx.payout_cents)), true) + row('Moyen de règlement', esc(ctx.method || '—')) + (refs ? row('Récompenses concernées', refs) : '')) +
        `<p style="margin:18px 0 0;font-size:13px;color:#4A5568;">Votre justificatif de règlement est disponible dans votre espace.</p>` +
        link,
    };
  }
  return null;
}
