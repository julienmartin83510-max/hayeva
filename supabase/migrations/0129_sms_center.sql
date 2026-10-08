-- 0129 — Centre de communication SMS (préparé, INACTIF par défaut).
--
-- Principe : chaque événement (confirmation, rappel J-1, déplacement,
-- annulation, « en route », message manuel) prépare une ligne dans
-- sms_messages. Tant que sms_settings.enabled = false (valeur par défaut),
-- la ligne est enregistrée avec le statut 'not_activated' : AUCUN SMS n'est
-- envoyé, aucun fournisseur n'est appelé. L'envoi réel n'est possible
-- qu'après : 1) un compte fournisseur ouvert par le propriétaire, 2) la clé
-- d'API enregistrée en secret Supabase, 3) l'activation dans l'admin.
--
-- SMS transactionnels uniquement (liés à un rendez-vous demandé par le
-- client) : aucun usage marketing. Désinscription par numéro
-- (sms_opt_outs), respectée par tous les envois, automatiques et manuels.
-- Tout est best-effort : une erreur SMS ne bloque jamais une réservation.

create table if not exists public.sms_settings (
  id integer primary key default 1 check (id = 1),
  enabled boolean not null default false,
  provider text check (provider in ('brevo', 'twilio')),
  sender_name text not null default 'HAYEVA' check (sender_name ~ '^[A-Za-z][A-Za-z0-9 ]{2,10}$'),
  auto_confirmation boolean not null default true,
  auto_reminder boolean not null default true,
  auto_change boolean not null default true,
  auto_on_the_way boolean not null default true,
  test_mode boolean not null default true,
  test_phone text,
  updated_at timestamptz not null default now(),
  updated_by uuid
);
insert into public.sms_settings (id) values (1) on conflict (id) do nothing;
alter table public.sms_settings enable row level security;

create table if not exists public.sms_messages (
  id uuid primary key default gen_random_uuid(),
  created_at timestamptz not null default now(),
  kind text not null check (kind in ('confirmation', 'reminder', 'rescheduled', 'cancelled', 'on_the_way', 'manual')),
  booking_id uuid, -- sans clé étrangère : l'historique survit à toute suppression
  client_id uuid,
  to_phone text,
  body text not null,
  status text not null check (status in ('not_activated', 'queued', 'sending', 'sent', 'failed',
                                         'skipped_opt_out', 'skipped_no_mobile', 'test_blocked')),
  dedupe_key text unique,
  provider text,
  provider_message_id text,
  error text,
  test_redirect boolean not null default false,
  sent_at timestamptz,
  created_by uuid
);
alter table public.sms_messages enable row level security;
create index if not exists sms_messages_created_idx on public.sms_messages (created_at desc);
create index if not exists sms_messages_status_idx on public.sms_messages (status) where status = 'queued';
create index if not exists sms_messages_client_idx on public.sms_messages (client_id);
create index if not exists sms_messages_booking_idx on public.sms_messages (booking_id);

create table if not exists public.sms_opt_outs (
  phone text primary key,
  created_at timestamptz not null default now(),
  source text not null check (source in ('client', 'admin', 'stop')),
  -- Désinscription annulée : active = false (trace conservée, jamais effacée).
  active boolean not null default true,
  updated_at timestamptz not null default now()
);
alter table public.sms_opt_outs enable row level security;

-- Lecture admin uniquement (aucune écriture directe : tout passe par les fonctions).
create policy "sms_settings: admin read" on public.sms_settings for select to authenticated using (is_admin());
create policy "sms_messages: admin read" on public.sms_messages for select to authenticated using (is_admin());
create policy "sms_opt_outs: admin read" on public.sms_opt_outs for select to authenticated using (is_admin());

-- Numéro mobile français au format international (+336… / +337…) ; null sinon.
create or replace function public.sms_mobile_e164(p text)
returns text
language sql
immutable
as $$
  select case
    when d ~ '^0[67][0-9]{8}$' then '+33' || substr(d, 2)
    when d ~ '^\+33[67][0-9]{8}$' then d
    when d ~ '^0033[67][0-9]{8}$' then '+' || substr(d, 3)
    else null end
  from (select regexp_replace(coalesce(p, ''), '[^0-9+]', '', 'g') as d) x;
$$;

-- Coordonnées SMS d'une réservation : invité, compte particulier, fiche
-- client, compte professionnel (même ordre que les e-mails).
create or replace function public.sms_booking_target(p_booking_id uuid, out phone text, out client_id uuid)
language plpgsql
stable
security definer
set search_path = public
as $$
declare b record;
begin
  select * into b from bookings where id = p_booking_id;
  if not found then return; end if;
  client_id := b.client_id;
  phone := sms_mobile_e164(b.guest_phone);
  if phone is null and b.customer_user_id is not null then
    select sms_mobile_e164(cp.phone) into phone from customer_profiles cp where cp.user_id = b.customer_user_id;
  end if;
  if phone is null and b.client_id is not null then
    select sms_mobile_e164(c.phone) into phone from clients c where c.id = b.client_id;
  end if;
  if phone is null and b.professional_account_id is not null then
    select sms_mobile_e164(pa.phone) into phone from professional_accounts pa where pa.id = b.professional_account_id;
  end if;
end;
$$;

create or replace function public.sms_fmt_day(d date) returns text language sql immutable as $$ select to_char(d, 'DD/MM') $$;
create or replace function public.sms_fmt_time(t time) returns text language sql immutable as $$ select to_char(t, 'HH24"h"MI') $$;

-- Déclenche l'envoi (après validation de la transaction) si un message attend.
create or replace function public.sms_kick_dispatch()
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  perform net.http_post(
    url := 'https://hvlzdsuyhrhaflwutwml.supabase.co/functions/v1/sms-dispatch',
    headers := jsonb_build_object('Content-Type', 'application/json',
      'x-cron-secret', (select decrypted_secret from vault.decrypted_secrets where name = 'hayeva_cron_shared_secret')),
    body := '{}'::jsonb);
exception when others then
  null; -- la tâche planifiée reprendra le message
end;
$$;

-- Prépare un SMS lié à un rendez-vous. Ne lève jamais d'erreur.
create or replace function public.sms_enqueue_booking(p_booking_id uuid, p_kind text, p_dedupe text, p_body text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  s sms_settings%rowtype;
  v_phone text; v_client uuid; v_status text; v_id uuid;
begin
  select * into s from sms_settings where id = 1;
  if (p_kind = 'confirmation' and not s.auto_confirmation)
     or (p_kind = 'reminder' and not s.auto_reminder)
     or (p_kind in ('rescheduled', 'cancelled') and not s.auto_change)
     or (p_kind = 'on_the_way' and not s.auto_on_the_way) then
    return;
  end if;
  select t.phone, t.client_id into v_phone, v_client from sms_booking_target(p_booking_id) t;
  v_status := case
    when v_phone is null then 'skipped_no_mobile'
    when exists (select 1 from sms_opt_outs o where o.phone = v_phone and o.active) then 'skipped_opt_out'
    when not s.enabled or s.provider is null then 'not_activated'
    else 'queued' end;
  insert into sms_messages (kind, booking_id, client_id, to_phone, body, status, dedupe_key)
  values (p_kind, p_booking_id, v_client, v_phone, p_body, v_status, p_dedupe)
  on conflict (dedupe_key) do nothing
  returning id into v_id;
  if v_id is not null and v_status = 'queued' then perform sms_kick_dispatch(); end if;
exception when others then
  raise warning 'sms_enqueue_booking: %', sqlerrm;
end;
$$;

-- Événements de réservation → SMS (confirmation, déplacement, annulation).
create or replace function public.sms_on_booking_change()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  begin
    if NEW.status = 'CONFIRMED' and OLD.status = 'PENDING' then
      perform sms_enqueue_booking(NEW.id, 'confirmation', 'confirmation:' || NEW.id,
        'HAYEVA : votre RDV est confirmé le ' || sms_fmt_day(NEW.date) || ' à ' || sms_fmt_time(NEW.start_time) || '. Infos ou changement : 06 71 26 23 02');
    elsif NEW.status = 'CONFIRMED' and OLD.status = 'CONFIRMED'
          and (NEW.date, NEW.start_time) is distinct from (OLD.date, OLD.start_time) then
      perform sms_enqueue_booking(NEW.id, 'rescheduled', 'rescheduled:' || NEW.id || ':' || NEW.date || ':' || NEW.start_time,
        'HAYEVA : votre RDV est déplacé au ' || sms_fmt_day(NEW.date) || ' à ' || sms_fmt_time(NEW.start_time) || '. Questions : 06 71 26 23 02');
    elsif NEW.status = 'CANCELLED' and OLD.status = 'CONFIRMED' then
      perform sms_enqueue_booking(NEW.id, 'cancelled', 'cancelled:' || NEW.id || ':' || OLD.date,
        'HAYEVA : votre RDV du ' || sms_fmt_day(OLD.date) || ' à ' || sms_fmt_time(OLD.start_time) || ' est annulé. Pour le reprogrammer : 06 71 26 23 02');
    end if;
  exception when others then
    raise warning 'sms_on_booking_change: %', sqlerrm;
  end;
  return NEW;
end;
$$;

create trigger trg_sms_on_booking_change
  after update of status, date, start_time on public.bookings
  for each row execute function public.sms_on_booking_change();

-- « Votre technicien est en route » (bouton de la vue technicien).
create or replace function public.sms_on_the_way()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  perform sms_enqueue_booking(NEW.booking_id, 'on_the_way', 'on_the_way:' || NEW.booking_id,
    'HAYEVA : votre technicien est en route, arrivée prévue vers ' ||
    to_char((NEW.created_at at time zone 'Europe/Paris') + make_interval(mins => coalesce(NEW.eta_minutes, 30)), 'HH24"h"MI') ||
    '. Contact : 06 71 26 23 02');
  return NEW;
exception when others then
  raise warning 'sms_on_the_way: %', sqlerrm;
  return NEW;
end;
$$;

create trigger trg_sms_on_the_way
  after insert on public.booking_on_the_way
  for each row execute function public.sms_on_the_way();

-- Rappel 24 h avant (tâche horaire ; un seul rappel par date grâce à la clé).
create or replace function public.sms_enqueue_reminders()
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare r record; n integer := 0; v_now timestamp := (now() at time zone 'Europe/Paris');
begin
  for r in
    select id, date, start_time from bookings
     where status = 'CONFIRMED'
       and (date + start_time) between v_now + interval '23 hours' and v_now + interval '25 hours'
  loop
    perform sms_enqueue_booking(r.id, 'reminder', 'reminder:' || r.id || ':' || r.date,
      'HAYEVA : rappel, votre RDV est demain ' || sms_fmt_day(r.date) || ' à ' || sms_fmt_time(r.start_time) || '. Empêchement ? 06 71 26 23 02');
    n := n + 1;
  end loop;
  return n;
end;
$$;

do $$
begin
  if not exists (select 1 from cron.job where jobname = 'hayeva-sms-reminders') then
    perform cron.schedule('hayeva-sms-reminders', '20 * * * *', 'select public.sms_enqueue_reminders();');
  end if;
  -- Filet de sécurité : relance l'envoi des messages en attente (ex. heures
  -- calmes, panne fournisseur). N'appelle la fonction que s'il y a du travail.
  if not exists (select 1 from cron.job where jobname = 'hayeva-sms-dispatch') then
    perform cron.schedule('hayeva-sms-dispatch', '*/10 * * * *',
      'select public.sms_kick_dispatch() where exists (select 1 from public.sms_messages where status = ''queued'');');
  end if;
end $$;

-- ---------- Administration ----------
create or replace function public.admin_get_sms_center(p_limit integer default 100)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare v jsonb;
begin
  if not is_admin() then raise exception 'Réservé à l''administration.'; end if;
  select jsonb_build_object(
    'settings', (select to_jsonb(s) - 'updated_by' from sms_settings s where id = 1),
    'counts_30d', (select coalesce(jsonb_object_agg(status, c), '{}'::jsonb) from (
        select status, count(*) c from sms_messages where created_at > now() - interval '30 days' group by status) t),
    'opt_outs', (select count(*) from sms_opt_outs where active),
    'messages', (select coalesce(jsonb_agg(m order by m.created_at desc), '[]'::jsonb) from (
        select sm.id, sm.created_at, sm.kind, sm.status, sm.body, sm.to_phone, sm.error, sm.sent_at, sm.test_redirect,
               sm.booking_id, sm.client_id,
               nullif(trim(coalesce(c.first_name, '') || ' ' || coalesce(c.last_name, '')), '') as client_name,
               b.reference
          from sms_messages sm
          left join clients c on c.id = sm.client_id
          left join bookings b on b.id = sm.booking_id
         order by sm.created_at desc
         limit greatest(1, least(coalesce(p_limit, 100), 300))) m)
  ) into v;
  return v;
end;
$$;

create or replace function public.admin_update_sms_settings(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare s sms_settings%rowtype; v_test text;
begin
  if not is_admin() then raise exception 'Réservé à l''administration.'; end if;
  select * into s from sms_settings where id = 1 for update;
  if p ? 'provider' then s.provider := nullif(p->>'provider', ''); end if;
  if p ? 'sender_name' then s.sender_name := coalesce(nullif(trim(p->>'sender_name'), ''), 'HAYEVA'); end if;
  if p ? 'auto_confirmation' then s.auto_confirmation := (p->>'auto_confirmation')::boolean; end if;
  if p ? 'auto_reminder' then s.auto_reminder := (p->>'auto_reminder')::boolean; end if;
  if p ? 'auto_change' then s.auto_change := (p->>'auto_change')::boolean; end if;
  if p ? 'auto_on_the_way' then s.auto_on_the_way := (p->>'auto_on_the_way')::boolean; end if;
  if p ? 'test_mode' then s.test_mode := (p->>'test_mode')::boolean; end if;
  if p ? 'test_phone' then
    v_test := nullif(trim(p->>'test_phone'), '');
    if v_test is not null and sms_mobile_e164(v_test) is null then
      raise exception 'Numéro de test invalide : indiquez un mobile français (06 ou 07).';
    end if;
    s.test_phone := sms_mobile_e164(v_test);
  end if;
  if p ? 'enabled' then s.enabled := (p->>'enabled')::boolean; end if;
  if s.enabled and s.provider is null then
    raise exception 'Choisissez d''abord un fournisseur SMS.';
  end if;
  update sms_settings set enabled = s.enabled, provider = s.provider, sender_name = s.sender_name,
    auto_confirmation = s.auto_confirmation, auto_reminder = s.auto_reminder, auto_change = s.auto_change,
    auto_on_the_way = s.auto_on_the_way, test_mode = s.test_mode, test_phone = s.test_phone,
    updated_at = now(), updated_by = auth.uid()
   where id = 1;
  return (select to_jsonb(x) - 'updated_by' from sms_settings x where id = 1);
end;
$$;

-- Envoi manuel depuis la fiche client.
create or replace function public.admin_queue_sms(p_client_id uuid, p_body text, p_booking_id uuid default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  s sms_settings%rowtype; v_phone text; v_status text; v_body text; v_id uuid;
begin
  if not is_admin() then raise exception 'Réservé à l''administration.'; end if;
  v_body := trim(coalesce(p_body, ''));
  if length(v_body) < 2 then raise exception 'Le message est vide.'; end if;
  if length(v_body) > 459 then raise exception 'Message trop long (459 caractères au maximum, soit 3 SMS).'; end if;
  select sms_mobile_e164(phone) into v_phone from clients where id = p_client_id;
  if v_phone is null then raise exception 'Aucun numéro de mobile valide sur cette fiche client.'; end if;
  if exists (select 1 from sms_opt_outs where phone = v_phone and active) then
    raise exception 'Ce client a refusé les SMS : aucun message ne peut lui être envoyé.';
  end if;
  select * into s from sms_settings where id = 1;
  v_status := case when s.enabled and s.provider is not null then 'queued' else 'not_activated' end;
  insert into sms_messages (kind, booking_id, client_id, to_phone, body, status, created_by)
  values ('manual', p_booking_id, p_client_id, v_phone, v_body, v_status, auth.uid())
  returning id into v_id;
  if v_status = 'queued' then perform sms_kick_dispatch(); end if;
  return jsonb_build_object('id', v_id, 'status', v_status);
end;
$$;

create or replace function public.admin_get_client_sms(p_client_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare v_phone text;
begin
  if not is_admin() then raise exception 'Réservé à l''administration.'; end if;
  select sms_mobile_e164(phone) into v_phone from clients where id = p_client_id;
  return jsonb_build_object(
    'mobile', v_phone,
    'opted_out', v_phone is not null and exists (select 1 from sms_opt_outs where phone = v_phone and active),
    'enabled', (select enabled and provider is not null from sms_settings where id = 1),
    'messages', (select coalesce(jsonb_agg(jsonb_build_object('created_at', created_at, 'kind', kind, 'status', status, 'body', body) order by created_at desc), '[]'::jsonb)
                   from (select * from sms_messages where client_id = p_client_id order by created_at desc limit 20) m));
end;
$$;

create or replace function public.admin_set_sms_opt_out(p_client_id uuid, p_opt_out boolean)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare v_phone text;
begin
  if not is_admin() then raise exception 'Réservé à l''administration.'; end if;
  select sms_mobile_e164(phone) into v_phone from clients where id = p_client_id;
  if v_phone is null then raise exception 'Aucun numéro de mobile valide sur cette fiche client.'; end if;
  if p_opt_out then
    insert into sms_opt_outs (phone, source) values (v_phone, 'admin')
      on conflict (phone) do update set active = true, source = 'admin', updated_at = now();
  else
    update sms_opt_outs set active = false, updated_at = now() where phone = v_phone;
  end if;
  return p_opt_out;
end;
$$;

-- ---------- Espace client : préférence SMS ----------
create or replace function public.get_my_sms_preference()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare v_phone text;
begin
  if auth.uid() is null then raise exception 'Authentification requise.'; end if;
  select sms_mobile_e164(phone) into v_phone from customer_profiles where user_id = auth.uid();
  return jsonb_build_object('mobile', v_phone is not null,
    'receive', v_phone is null or not exists (select 1 from sms_opt_outs where phone = v_phone and active));
end;
$$;

create or replace function public.set_my_sms_preference(p_receive boolean)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare v_phone text;
begin
  if auth.uid() is null then raise exception 'Authentification requise.'; end if;
  select sms_mobile_e164(phone) into v_phone from customer_profiles where user_id = auth.uid();
  if v_phone is null then return jsonb_build_object('mobile', false, 'receive', p_receive); end if;
  if p_receive then
    update sms_opt_outs set active = false, updated_at = now() where phone = v_phone;
  else
    insert into sms_opt_outs (phone, source) values (v_phone, 'client')
      on conflict (phone) do update set active = true, source = 'client', updated_at = now();
  end if;
  return jsonb_build_object('mobile', true, 'receive', p_receive);
end;
$$;

revoke all on function public.sms_booking_target(uuid) from public, anon, authenticated;
revoke all on function public.sms_kick_dispatch() from public, anon, authenticated;
revoke all on function public.sms_enqueue_booking(uuid, text, text, text) from public, anon, authenticated;
revoke all on function public.sms_enqueue_reminders() from public, anon, authenticated;
revoke all on function public.sms_on_booking_change() from public, anon, authenticated;
revoke all on function public.sms_on_the_way() from public, anon, authenticated;
revoke all on function public.admin_get_sms_center(integer) from public, anon;
revoke all on function public.admin_update_sms_settings(jsonb) from public, anon;
revoke all on function public.admin_queue_sms(uuid, text, uuid) from public, anon;
revoke all on function public.admin_get_client_sms(uuid) from public, anon;
revoke all on function public.admin_set_sms_opt_out(uuid, boolean) from public, anon;
revoke all on function public.get_my_sms_preference() from public, anon;
revoke all on function public.set_my_sms_preference(boolean) from public, anon;
grant execute on function public.admin_get_sms_center(integer), public.admin_update_sms_settings(jsonb),
  public.admin_queue_sms(uuid, text, uuid), public.admin_get_client_sms(uuid), public.admin_set_sms_opt_out(uuid, boolean),
  public.get_my_sms_preference(), public.set_my_sms_preference(boolean) to authenticated;
