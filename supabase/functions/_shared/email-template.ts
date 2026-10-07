// Gabarit visuel PARTAGÉ par tous les e-mails automatiques HAYEVA (notify-
// admin-booking, notify-customer-booking, notify-customer-status-change,
// resend-booking-email) — une seule source de vérité pour l'identité
// visuelle, garantissant que tous les e-mails se ressemblent.
//
// En-tête : bannière HAYEVA officielle (paysage + logo centré, fichier
// images/email/hayeva-email-header.jpg, 1200×675 pour les écrans Retina),
// affichée EN ENTIER (largeur 100 %, hauteur proportionnelle) : jamais
// recadrée ni zoomée, quel que soit l'écran. Couleur de secours marine et
// texte alternatif lisible si le client mail bloque les images.

// Ce module ne construit QUE l'enveloppe visuelle (en-tête + pied de page) :
// chaque fonction appelante continue de construire son propre contenu
// (bodyHtml) exactement comme avant — aucune logique d'envoi, de données
// Supabase ni de réservation n'est concernée par ce fichier.
//
// Contraintes e-mail : HTML à base de <table> et styles inline (pas de
// classes CSS externes, peu fiables selon les clients), image en <img>
// (et non en fond CSS) pour un affichage fiable partout, y compris Outlook
// desktop, et une couleur de secours (#101B24) si l'image ne s'affiche pas.

const SITE_BASE_URL = Deno.env.get('SITE_BASE_URL') || 'https://hayeva.netlify.app';
const HEADER_IMAGE_URL = `${SITE_BASE_URL}/images/email/hayeva-email-header.jpg`;
const NAVY = '#101B24';

type BadgeTone = 'received' | 'confirmed' | 'cancelled' | 'rescheduled';

const BADGE_COLORS: Record<BadgeTone, { bg: string; fg: string }> = {
  received: { bg: '#FCEFD9', fg: '#8A6416' },
  confirmed: { bg: '#DFF3E6', fg: '#2F7A4F' },
  cancelled: { bg: '#FBE3DE', fg: '#B23A3A' },
  rescheduled: { bg: '#D9EAFB', fg: '#205A8F' },
};

// "Joli encadré" de statut (demande reçue / confirmée / annulée) : label déjà
// échappé/composé par l'appelant (toujours un texte fixe côté serveur dans
// ce projet, jamais une valeur saisie par un client).
export function statusBadgeHtml(label: string, tone: BadgeTone): string {
  const c = BADGE_COLORS[tone] || BADGE_COLORS.received;
  return `
    <table role="presentation" cellpadding="0" cellspacing="0" border="0" style="margin:0 0 20px;">
      <tr>
        <td style="background-color:${c.bg}; color:${c.fg}; font-family:Arial,Helvetica,sans-serif; font-weight:700; font-size:13px; border-radius:999px; padding:8px 18px;">
          ${label}
        </td>
      </tr>
    </table>`;
}

// Enveloppe complète : en-tête (bannière HAYEVA), bodyHtml fourni par
// l'appelant, puis pied de page (équipe + activités + référence). reference
// est déjà échappée par l'appelant (même habitude que le reste du fichier
// source, même si booking.reference est en pratique un slug généré côté
// serveur, jamais une saisie utilisateur).
export function renderEmailShell(bodyHtml: string, reference?: string): string {
  return `<!doctype html>
<html lang="fr">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<meta http-equiv="X-UA-Compatible" content="IE=edge">
<!--[if mso]>
<noscript><xml><o:OfficeDocumentSettings><o:PixelsPerInch>96</o:PixelsPerInch></o:OfficeDocumentSettings></xml></noscript>
<![endif]-->
<title>HAYEVA</title>
</head>
<body style="margin:0; padding:0; background-color:#F4F1EA;">
  <table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="background-color:#F4F1EA;">
    <tr>
      <td align="center" style="padding:24px 12px;">
        <table role="presentation" width="600" cellpadding="0" cellspacing="0" border="0" style="width:100%; max-width:600px; background-color:#ffffff; border-radius:16px; overflow:hidden;">
          <tr>
            <td align="center" bgcolor="${NAVY}" style="padding:0; background-color:${NAVY};">
              <img src="${HEADER_IMAGE_URL}" width="600" alt="HAYEVA — Plomberie • Chauffage • Climatisation" style="display:block; width:100%; max-width:600px; height:auto; border:0; outline:none; text-decoration:none; color:#ffffff; font-family:Arial,Helvetica,sans-serif; font-size:18px; font-weight:700; text-align:center;">
            </td>
          </tr>
          <tr>
            <td style="padding:32px 30px 28px; font-family:Arial,Helvetica,sans-serif; color:#16222C; line-height:1.55;">
              ${bodyHtml}
            </td>
          </tr>
          <tr>
            <td style="padding:20px 30px 28px; border-top:1px solid #EFE9DB; font-family:Arial,Helvetica,sans-serif;">
              <p style="margin:0 0 4px; font-size:13px; font-weight:700; color:#101B24;">L'équipe HAYEVA</p>
              <p style="margin:0 0 10px; font-size:12px; color:#8A97A3;">Plomberie • Chauffage • Climatisation</p>
              ${reference ? `<p style="margin:0 0 10px; font-size:11px; color:#B7BFC6;">Réf. ${reference}</p>` : ''}
              <p style="margin:0; font-size:11px; color:#B7BFC6;">
                <a href="${SITE_BASE_URL}/#legal/mentions" style="color:#8A97A3; text-decoration:underline;">Mentions légales</a>
                &nbsp;·&nbsp;
                <a href="${SITE_BASE_URL}/#legal/cgv" style="color:#8A97A3; text-decoration:underline;">CGV</a>
                &nbsp;·&nbsp;
                <a href="${SITE_BASE_URL}/#legal/confidentialite" style="color:#8A97A3; text-decoration:underline;">Confidentialité</a>
                &nbsp;·&nbsp;
                <a href="${SITE_BASE_URL}/#legal/retractation" style="color:#8A97A3; text-decoration:underline;">Rétractation</a>
              </p>
            </td>
          </tr>
        </table>
      </td>
    </tr>
  </table>
</body>
</html>`;
}
