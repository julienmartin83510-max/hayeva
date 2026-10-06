-- Validation des demandes de rendez-vous DIRECTEMENT depuis l'e-mail admin
-- (boutons "CONFIRMER" / "REFUSER") + anti-doublons des e-mails.
--
-- Jetons : 32 octets aléatoires générés côté serveur (Edge Function
-- notify-admin-booking) ; SEUL leur hash SHA-256 est stocké ici. Un jeton
-- est lié à UNE réservation et UNE action, expire, et TOUS les jetons d'une
-- réservation sont invalidés dès que l'un d'eux est utilisé. Table sans
-- aucune policy RLS : inaccessible aux rôles anon/authenticated, lue
-- uniquement par la fonction ci-dessous (appelée par l'Edge Function
-- booking-email-action avec la clé service_role, jamais exposée).

create table if not exists public.booking_action_tokens (
  id uuid primary key default gen_random_uuid(),
  booking_id uuid not null references public.bookings(id) on delete cascade,
  action text not null check (action in ('confirm', 'refuse')),
  token_hash text not null unique,
  expires_at timestamptz not null,
  used_at timestamptz,
  created_at timestamptz not null default now()
);
create index if not exists booking_action_tokens_booking_idx on public.booking_action_tokens (booking_id);
alter table public.booking_action_tokens enable row level security;
revoke all on public.booking_action_tokens from anon, authenticated;

-- Anti-doublons : une clé unique par (action, réservation, destinataire) —
-- un webhook rejoué, un double appel réseau ou un rafraîchissement ne
-- peuvent plus produire un second e-mail.
alter table public.booking_emails add column if not exists dedupe_key text;
create unique index if not exists booking_emails_dedupe_key_uidx
  on public.booking_emails (dedupe_key) where dedupe_key is not null;
alter table public.booking_emails drop constraint if exists booking_emails_email_type_check;
alter table public.booking_emails add constraint booking_emails_email_type_check
  check (email_type in ('received', 'confirmed', 'cancelled', 'refused', 'rescheduled',
                        'admin_new', 'admin_cancelled', 'admin_rescheduled'));

-- Traitement d'un clic CONFIRMER / REFUSER.
--   p_execute = false : simple lecture (affichage de la page de validation).
--   p_execute = true  : exécute l'action si tout est valide.
-- Résultats : invalid | expired | already | ready | done.
create or replace function public.process_booking_email_action(p_token_hash text, p_action text, p_execute boolean)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_token booking_action_tokens%rowtype;
  v_booking bookings%rowtype;
  v_client text;
  v_service text;
  v_info jsonb;
begin
  if p_action not in ('confirm', 'refuse') or coalesce(length(p_token_hash), 0) <> 64 then
    return jsonb_build_object('result', 'invalid');
  end if;

  select * into v_token from booking_action_tokens
   where token_hash = p_token_hash and action = p_action
   for update;
  if not found then
    return jsonb_build_object('result', 'invalid');
  end if;

  select * into v_booking from bookings where id = v_token.booking_id for update;
  if not found then
    return jsonb_build_object('result', 'invalid');
  end if;

  select coalesce(
           nullif(v_booking.guest_name, ''),
           (select nullif(trim(concat_ws(' ', cp.first_name, cp.last_name)), '') from customer_profiles cp where cp.user_id = v_booking.customer_user_id),
           (select pa.legal_name from professional_accounts pa where pa.id = v_booking.professional_account_id),
           'Client')
    into v_client;
  select name into v_service from services where id = v_booking.service_id;

  v_info := jsonb_build_object(
    'reference', v_booking.reference,
    'client', v_client,
    'service', coalesce(v_service, 'Intervention'),
    'date', v_booking.date,
    'start_time', to_char(v_booking.start_time, 'HH24:MI'),
    'status', v_booking.status,
    'cancellation_type', v_booking.cancellation_type
  );

  if v_token.used_at is not null or v_booking.status <> 'PENDING' then
    return jsonb_build_object('result', 'already', 'booking', v_info);
  end if;
  if v_token.expires_at < now() or v_booking.date < (now() at time zone 'Europe/Paris')::date then
    return jsonb_build_object('result', 'expired', 'booking', v_info);
  end if;
  if not p_execute then
    return jsonb_build_object('result', 'ready', 'booking', v_info);
  end if;

  perform set_config('app.allow_status_change', 'on', true);
  if p_action = 'confirm' then
    update bookings set status = 'CONFIRMED', admin_viewed_at = coalesce(admin_viewed_at, now()), updated_at = now()
     where id = v_booking.id;
  else
    update bookings
       set status = 'CANCELLED', cancelled_by = 'admin', cancelled_at = now(),
           cancellation_type = 'refused', cancellation_reason_code = 'creneau_indisponible',
           admin_viewed_at = coalesce(admin_viewed_at, now()), updated_at = now()
     where id = v_booking.id;
  end if;

  update booking_action_tokens set used_at = now() where booking_id = v_booking.id and used_at is null;

  return jsonb_build_object('result', 'done', 'action', p_action,
    'booking', v_info || jsonb_build_object('status', case when p_action = 'confirm' then 'CONFIRMED' else 'CANCELLED' end));
end;
$$;
revoke all on function public.process_booking_email_action(text, text, boolean) from public, anon, authenticated;
grant execute on function public.process_booking_email_action(text, text, boolean) to service_role;
