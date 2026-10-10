// Supabase Edge Function — téléchargement d'un justificatif de parrainage
// (attestation, relevé, justificatif de règlement).
//
// 1. issue_referral_document() est appelée AVEC LA SESSION de l'utilisateur :
//    la base vérifie qu'il est bien le parrain concerné (ou administrateur) et
//    que la situation réelle autorise ce document ; elle fige son contenu.
// 2. Le PDF est mis en page ici (jamais dans le navigateur), archivé dans le
//    stockage privé referral-documents avec son empreinte SHA-256, puis
//    renvoyé. Un document déjà émis est toujours resservi à l'identique.

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';
import * as pdfLib from 'https://esm.sh/pdf-lib@1.17.1';
import qrcode from 'https://esm.sh/qrcode-generator@1.4.4';
import { buildReferralPdf } from '../_shared/referral-pdf.mjs';

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
const ANON_KEY = Deno.env.get('SUPABASE_ANON_KEY')!;
const SERVICE_ROLE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
const SITE_URL = Deno.env.get('PUBLIC_SITE_URL') || 'https://hayeva.fr';
const ALLOWED_ORIGINS = [SITE_URL, 'https://www.hayeva.fr'];
const BUCKET = 'referral-documents';
const ERRORS: Record<string, [number, string]> = {
  AUTH_REQUIRED: [401, 'Votre session a expiré. Reconnectez-vous pour continuer.'],
  INTROUVABLE: [404, 'Document introuvable.'],
  TYPE_INCONNU: [400, 'Type de document inconnu.'],
  RECOMPENSE_NON_VALIDEE: [409, 'Le relevé sera disponible lorsque la récompense aura été validée.'],
  REGLEMENT_NON_CONFIRME: [409, 'Le justificatif sera disponible lorsque le règlement aura été effectué.'],
};

let logoCache: Uint8Array | null = null;
async function logo(): Promise<Uint8Array | null> {
  if (logoCache) return logoCache;
  const r = await fetch(`${SITE_URL}/images/brand/hayeva-logo-sm.png`);
  if (!r.ok) return null;
  logoCache = new Uint8Array(await r.arrayBuffer());
  return logoCache;
}
async function sha256(bytes: Uint8Array): Promise<string> {
  const h = new Uint8Array(await crypto.subtle.digest('SHA-256', bytes));
  return Array.from(h, (b) => b.toString(16).padStart(2, '0')).join('');
}

Deno.serve(async (req: Request) => {
  const origin = req.headers.get('origin') || '';
  const cors = {
    'Access-Control-Allow-Origin': ALLOWED_ORIGINS.includes(origin) ? origin : SITE_URL,
    'Access-Control-Allow-Headers': 'authorization, content-type, apikey, x-client-info',
    'Access-Control-Allow-Methods': 'POST, OPTIONS',
    'Access-Control-Expose-Headers': 'content-disposition, x-document-number',
    'Vary': 'Origin',
  };
  const fail = (code: string) => {
    const [status, message] = ERRORS[code] || [500, 'Le document n\'a pas pu être préparé. Réessayez dans un instant.'];
    return new Response(JSON.stringify({ ok: false, error: code, message }), { status, headers: { ...cors, 'Content-Type': 'application/json' } });
  };
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors });
  if (req.method !== 'POST') return fail('METHOD');
  const auth = req.headers.get('authorization') || '';
  if (!/^Bearer\s+\S+/.test(auth)) return fail('AUTH_REQUIRED');

  try {
    const body = await req.json().catch(() => ({}));
    const kind = String(body?.kind || '');
    const subject = String(body?.subject_id || '');
    if (!/^[0-9a-f-]{36}$/i.test(subject)) return fail('INTROUVABLE');

    const asUser = createClient(SUPABASE_URL, ANON_KEY, { global: { headers: { Authorization: auth } }, auth: { persistSession: false } });
    const { data: doc, error } = await asUser.rpc('issue_referral_document', { p_kind: kind, p_subject_id: subject });
    if (error) { console.error('referral-document: émission impossible', error.message); return fail('INTERNAL'); }
    if (!doc?.ok) return fail(doc?.error || 'INTERNAL');

    const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, { auth: { persistSession: false } });
    const path = `${doc.id}.pdf`;
    let bytes: Uint8Array | null = null;
    if (doc.has_file) {
      const { data: file } = await admin.storage.from(BUCKET).download(path);
      if (file) bytes = new Uint8Array(await file.arrayBuffer());
    }
    if (!bytes) {
      const built: Uint8Array = await buildReferralPdf(pdfLib, qrcode, doc, await logo(), { verifyBaseUrl: `${SITE_URL}/verification` });
      bytes = built;
      const { error: upErr } = await admin.storage.from(BUCKET).upload(path, built, { contentType: 'application/pdf', upsert: false });
      if (!upErr) await admin.rpc('referral_document_attach_file', { p_id: doc.id, p_path: path, p_sha256: await sha256(built) });
      else if (!/exists/i.test(upErr.message)) console.error('referral-document: archivage impossible', upErr.message);
    }
    return new Response(bytes, { status: 200, headers: { ...cors, 'Content-Type': 'application/pdf', 'Cache-Control': 'no-store',
      'Content-Disposition': `attachment; filename="HAYEVA-${doc.number}.pdf"`, 'X-Document-Number': doc.number } });
  } catch (err) {
    console.error('referral-document: erreur inattendue', err instanceof Error ? err.message : String(err));
    return fail('INTERNAL');
  }
});
