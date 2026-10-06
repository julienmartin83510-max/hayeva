// Envoi d'e-mail "une seule fois" (anti-doublons) partagé par les fonctions
// de notification HAYEVA.
//
// Chaque envoi porte une clé métier unique (dedupeKey, ex.
// "admin_new:<booking_id>") enregistrée dans booking_emails (index unique,
// voir 0071_booking_email_actions.sql) AVANT l'appel Resend : un webhook
// rejoué, un double appel réseau ou un rafraîchissement retrouvent la clé
// et n'envoient rien. La même clé est passée à Resend (Idempotency-Key) pour
// couvrir aussi une relance réseau de l'appel HTTP lui-même. Seul un envoi
// précédemment ÉCHOUÉ peut être retenté.
//
// RESEND_API_KEY reste un secret de la fonction (jamais exposé).

// deno-lint-ignore no-explicit-any
type Sb = any;

const RESEND_API_KEY = Deno.env.get('RESEND_API_KEY');
const FROM_EMAIL = Deno.env.get('RESEND_FROM_EMAIL') || 'HAYEVA <onboarding@resend.dev>';
const REPLY_TO_EMAIL = Deno.env.get('REPLY_TO_EMAIL') || 'contact@hayeva.fr';

// Adresse de notification admin : contact@hayeva.fr (demande explicite),
// surchargeable par le secret ADMIN_BOOKING_EMAIL si besoin un jour.
export const ADMIN_BOOKING_EMAIL = Deno.env.get('ADMIN_BOOKING_EMAIL') || 'contact@hayeva.fr';

export type SendOnceInput = {
  dedupeKey: string;
  bookingId: string;
  emailType: string;
  to: string;
  subject: string;
  html: string;
};

export async function sendEmailOnce(supabase: Sb, m: SendOnceInput): Promise<'sent' | 'duplicate' | 'failed'> {
  let logId: string | null = null;
  let idemKey = m.dedupeKey;
  const { data: inserted, error: insErr } = await supabase
    .from('booking_emails')
    .insert({ booking_id: m.bookingId, email_type: m.emailType, status: 'pending', recipient_email: m.to || null, dedupe_key: m.dedupeKey })
    .select('id')
    .maybeSingle();
  if (inserted) {
    logId = inserted.id;
  } else if (insErr && insErr.code === '23505') {
    // Déjà traité : on ne retente que si l'envoi précédent a échoué.
    const { data: retry } = await supabase
      .from('booking_emails')
      .update({ status: 'pending', error_message: null })
      .eq('dedupe_key', m.dedupeKey)
      .eq('status', 'failed')
      .select('id')
      .maybeSingle();
    if (!retry) return 'duplicate';
    logId = retry.id;
    idemKey = `${m.dedupeKey}:retry:${Date.now()}`;
  } else if (insErr) {
    console.error('sendEmailOnce: journalisation impossible', insErr.message);
    return 'failed';
  }

  const fail = async (msg: string) => {
    if (logId) await supabase.from('booking_emails').update({ status: 'failed', error_message: msg.slice(0, 500) }).eq('id', logId);
    return 'failed' as const;
  };
  if (!m.to) return await fail('Aucune adresse e-mail associée à cette réservation.');
  if (!RESEND_API_KEY) return await fail('RESEND_API_KEY manquant.');

  const res = await fetch('https://api.resend.com/emails', {
    method: 'POST',
    headers: {
      Authorization: `Bearer ${RESEND_API_KEY}`,
      'Content-Type': 'application/json',
      'Idempotency-Key': idemKey.slice(0, 256),
    },
    body: JSON.stringify({ from: FROM_EMAIL, to: [m.to], reply_to: REPLY_TO_EMAIL, subject: m.subject, html: m.html }),
  });
  if (!res.ok) {
    const t = await res.text();
    console.error('sendEmailOnce: échec Resend', m.emailType, res.status, t);
    return await fail(`Resend ${res.status}: ${t}`);
  }
  if (logId) await supabase.from('booking_emails').update({ status: 'sent', sent_at: new Date().toISOString() }).eq('id', logId);
  return 'sent';
}

// Gros bouton e-mail (table + lien, compatible Outlook/Gmail/Apple Mail).
export function bigButtonHtml(href: string, label: string, bg: string): string {
  return `
    <table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="margin:0 0 12px;">
      <tr><td align="center" bgcolor="${bg}" style="border-radius:12px;background:${bg};">
        <a href="${href}" target="_blank" style="display:block;padding:18px 12px;font-family:Arial,Helvetica,sans-serif;font-size:17px;font-weight:700;color:#ffffff;text-decoration:none;border-radius:12px;">${label}</a>
      </td></tr>
    </table>`;
}
