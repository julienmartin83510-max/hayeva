// Résolution des coordonnées d'une réservation (invité / particulier
// connecté / professionnel) — utilisée par les e-mails admin.

// deno-lint-ignore no-explicit-any
type Sb = any;

export type BookingContact = {
  name: string;
  firstName: string;
  phone: string;
  email: string;
  address: string;
  kind: 'Particulier' | 'Professionnel';
};

// deno-lint-ignore no-explicit-any
export async function resolveBookingContact(supabase: Sb, booking: any): Promise<BookingContact> {
  const c: BookingContact = { name: 'Client', firstName: '', phone: '', email: '', address: '', kind: 'Particulier' };
  if (booking.guest_name) {
    c.name = booking.guest_name;
    c.phone = booking.guest_phone || '';
    c.email = booking.guest_email || '';
    c.address = booking.guest_address || '';
  } else if (booking.customer_user_id) {
    const [{ data: cp }, { data: prof }] = await Promise.all([
      supabase.from('customer_profiles').select('first_name,last_name,phone').eq('user_id', booking.customer_user_id).maybeSingle(),
      supabase.from('profiles').select('email').eq('user_id', booking.customer_user_id).maybeSingle(),
    ]);
    if (cp) {
      c.name = [cp.first_name, cp.last_name].filter(Boolean).join(' ') || c.name;
      c.phone = cp.phone || '';
    }
    if (prof) c.email = prof.email || '';
    if (booking.customer_address_id) {
      const { data: addr } = await supabase.from('customer_addresses').select('address,postal_code,city').eq('id', booking.customer_address_id).maybeSingle();
      if (addr) c.address = [addr.address, addr.postal_code, addr.city].filter(Boolean).join(', ');
    }
  } else if (booking.professional_account_id) {
    c.kind = 'Professionnel';
    const { data: pa } = await supabase
      .from('professional_accounts')
      .select('legal_name,phone,address_line1,address_line2,postal_code,city,created_by')
      .eq('id', booking.professional_account_id)
      .maybeSingle();
    if (pa) {
      c.name = pa.legal_name || c.name;
      c.phone = pa.phone || '';
      c.address = [pa.address_line1, pa.address_line2, pa.postal_code, pa.city].filter(Boolean).join(', ');
      if (pa.created_by) {
        const { data: prof } = await supabase.from('profiles').select('email').eq('user_id', pa.created_by).maybeSingle();
        if (prof) c.email = prof.email || '';
      }
    }
  }
  if (booking.client_id && c.kind === 'Particulier') {
    const { data: cl } = await supabase.from('clients').select('client_type').eq('id', booking.client_id).maybeSingle();
    if (cl && /^pro/i.test(String(cl.client_type || ''))) c.kind = 'Professionnel';
  }
  c.firstName = String(c.name).trim().split(/\s+/)[0] || '';
  return c;
}

export function escapeHtml(s: string): string {
  return String(s).replace(/[&<>"']/g, (ch) => (
    { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[ch] as string
  ));
}
export function fmtDate(d: string): string {
  const [y, m, day] = String(d).slice(0, 10).split('-');
  return `${day}/${m}/${y}`;
}
export function fmtTime(t: string): string {
  return String(t || '').slice(0, 5);
}
export function fmtDuration(min: number): string {
  const m = Number(min) || 0;
  if (!m) return '—';
  const h = Math.floor(m / 60);
  const r = m % 60;
  return h ? `${h} h${r ? ` ${String(r).padStart(2, '0')}` : ''}` : `${r} min`;
}

// Ligne de tableau standard des e-mails HAYEVA (valeur déjà échappée).
export function rowHtml(label: string, valueHtml: string, strong = false): string {
  return `<tr><td style="padding:7px 0;color:#5B6B78;width:140px;vertical-align:top;">${label}</td><td style="padding:7px 0;text-align:right;${strong ? 'font-weight:700;' : ''}">${valueHtml || '—'}</td></tr>`;
}
