// Architecture SMS prête à brancher sur un fournisseur réel, sans jamais en
// simuler un. Aucun compte SMS (Twilio, Vonage, OVH, Free Mobile...) n'existe
// aujourd'hui pour HAYEVA — inventer des identifiants ou un envoi fictif
// romprait la confiance du client (un "rappel envoyé" qui ne l'a jamais été).
//
// Pour activer un fournisseur réel plus tard : définir les secrets
// SMS_PROVIDER ('twilio' pour l'instant) + les identifiants associés
// (TWILIO_ACCOUNT_SID, TWILIO_AUTH_TOKEN, TWILIO_FROM_NUMBER), puis
// compléter la branche correspondante ci-dessous. Tant qu'aucun provider
// n'est configuré, sendReminderSMS() ne tente rien et le retourne
// explicitement pour que l'appelant (ex. process-reminders) marque le job
// 'failed' avec cette raison précise, jamais 'sent'.

export type SmsResult =
  | { ok: true; provider: string; externalId?: string }
  | { ok: false; reason: 'SMS_READY_NOT_CONFIGURED' | 'SMS_SEND_FAILED'; detail?: string };

export async function sendReminderSMS(toPhoneNumber: string, message: string): Promise<SmsResult> {
  const provider = Deno.env.get('SMS_PROVIDER');

  if (!provider) {
    console.warn('sendReminderSMS: aucun SMS_PROVIDER configuré — SMS_READY_NOT_CONFIGURED', { toPhoneNumber });
    return { ok: false, reason: 'SMS_READY_NOT_CONFIGURED' };
  }

  if (provider === 'twilio') {
    const sid = Deno.env.get('TWILIO_ACCOUNT_SID');
    const token = Deno.env.get('TWILIO_AUTH_TOKEN');
    const from = Deno.env.get('TWILIO_FROM_NUMBER');
    if (!sid || !token || !from) {
      console.warn('sendReminderSMS: SMS_PROVIDER=twilio mais identifiants incomplets');
      return { ok: false, reason: 'SMS_READY_NOT_CONFIGURED' };
    }
    try {
      const res = await fetch(`https://api.twilio.com/2010-04-01/Accounts/${sid}/Messages.json`, {
        method: 'POST',
        headers: {
          Authorization: 'Basic ' + btoa(`${sid}:${token}`),
          'Content-Type': 'application/x-www-form-urlencoded',
        },
        body: new URLSearchParams({ To: toPhoneNumber, From: from, Body: message }).toString(),
      });
      const payload = await res.json().catch(() => ({}));
      if (!res.ok) return { ok: false, reason: 'SMS_SEND_FAILED', detail: `twilio_${res.status}` };
      return { ok: true, provider: 'twilio', externalId: payload?.sid };
    } catch (err) {
      return { ok: false, reason: 'SMS_SEND_FAILED', detail: String(err instanceof Error ? err.message : err) };
    }
  }

  console.warn('sendReminderSMS: SMS_PROVIDER inconnu', provider);
  return { ok: false, reason: 'SMS_READY_NOT_CONFIGURED' };
}
