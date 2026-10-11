-- EVA — assistante de gestion HAYEVA (V1, sans IA payante).
--
-- Principe : EVA ne « devine » rien. Une commande en français est traduite
-- dans le navigateur en une intention parmi une liste fermée ; le serveur
-- (eva_run) vérifie le rôle administrateur, l'activation de l'agent et le
-- débit, puis exécute des lectures déterministes sur les données réelles.
-- Les seules écritures passent par des propositions (eva_proposals) que
-- l'administrateur confirme explicitement ; leur exécution réutilise les
-- fonctions existantes (admin_create_invoice, admin_reschedule_booking…)
-- avec tous leurs contrôles. Aucun appel à un service externe.
--
-- Contenu (ajouts uniquement, aucune donnée supprimée) :
--   1. Horaires de travail et marge de trajet réglables (booking_settings),
--      valeurs par défaut STRICTEMENT identiques aux horaires codés jusqu'ici
--      (lun–ven 8 h–13 h / 14 h–18 h, sam 8 h–12 h, dimanche fermé).
--   2. Régime de TVA à confirmer explicitement avant toute facture définitive.
--   3. Réglages, journal et propositions d'EVA.
--   4. Agents Planning, Devis, Factures (lecture) + propositions.

-- =====================================================================
-- 1) Horaires de travail et marge de trajet
-- =====================================================================
create or replace function public.eva_hhmm_minutes(p text)
returns integer language sql immutable as $$
  select case when p ~ '^([01][0-9]|2[0-3]):[0-5][0-9]$'
              then split_part(p, ':', 1)::int * 60 + split_part(p, ':', 2)::int end
$$;

create or replace function public.work_hours_valid(p jsonb)
returns boolean language plpgsql immutable as $$
declare d int; r jsonb; s int; e int; prev int;
begin
  if p is null or jsonb_typeof(p) <> 'object' then return false; end if;
  for d in 1..7 loop
    if jsonb_typeof(p -> d::text) is distinct from 'array' then return false; end if;
    if jsonb_array_length(p -> d::text) > 4 then return false; end if;
    prev := -1;
    for r in select value from jsonb_array_elements(p -> d::text) loop
      if jsonb_typeof(r) <> 'array' or jsonb_array_length(r) <> 2 then return false; end if;
      s := eva_hhmm_minutes(r ->> 0); e := eva_hhmm_minutes(r ->> 1);
      if s is null or e is null or s >= e or s < 300 or e > 1320 or s % 5 <> 0 or e % 5 <> 0 or s < prev then return false; end if;
      prev := e;
    end loop;
  end loop;
  return true;
end $$;

alter table public.booking_settings
  add column if not exists work_hours jsonb not null default
    '{"1":[["08:00","13:00"],["14:00","18:00"]],"2":[["08:00","13:00"],["14:00","18:00"]],"3":[["08:00","13:00"],["14:00","18:00"]],"4":[["08:00","13:00"],["14:00","18:00"]],"5":[["08:00","13:00"],["14:00","18:00"]],"6":[["08:00","12:00"]],"7":[]}'::jsonb,
  add column if not exists travel_margin_minutes integer not null default 30;
do $$ begin
  alter table public.booking_settings add constraint booking_settings_work_hours_valid check (work_hours_valid(work_hours));
exception when duplicate_object then null; end $$;
do $$ begin
  alter table public.booking_settings add constraint booking_settings_travel_margin_range check (travel_margin_minutes between 0 and 180);
exception when duplicate_object then null; end $$;

-- Plages (en minutes depuis minuit) d'une journée, selon le réglage.
create or replace function public.work_ranges(p_date date)
returns int4range[] language sql stable security definer set search_path = public as $$
  select coalesce(array_agg(int4range(eva_hhmm_minutes(r ->> 0), eva_hhmm_minutes(r ->> 1)) order by eva_hhmm_minutes(r ->> 0)), '{}')
    from booking_settings bs, jsonb_array_elements(coalesce(bs.work_hours -> extract(isodow from p_date)::int::text, '[]'::jsonb)) r
   where bs.id = 1
$$;
revoke all on function public.work_ranges(date) from public, anon, authenticated;

-- Même signature, même usage : désormais lue depuis le réglage.
create or replace function public.is_slot_within_business_hours(p_date date, p_start_time time, p_duration_minutes integer)
returns boolean language plpgsql stable security definer set search_path = public as $$
declare v_s int := extract(hour from p_start_time)::int * 60 + extract(minute from p_start_time)::int;
begin
  return exists (select 1 from unnest(work_ranges(p_date)) r
                  where v_s >= lower(r) and v_s + coalesce(p_duration_minutes, 60) <= upper(r));
end $$;
revoke all on function public.is_slot_within_business_hours(date, time, integer) from public;
grant execute on function public.is_slot_within_business_hours(date, time, integer) to authenticated, anon;

-- Créneaux libres pour un déplacement (lien d'e-mail) : identique à 0119,
-- seules les plages horaires viennent du réglage.
create or replace function public.booking_free_slots(p_booking_id uuid, p_date date)
returns setof time language plpgsql stable security definer set search_path = public as $$
declare
  b public.bookings; v_dur integer; v_step integer; v_ranges int4range[]; r int4range; t integer;
  v_open date; v_mb integer; v_ma integer; v_now_paris timestamp := now() at time zone 'Europe/Paris';
begin
  select * into b from public.bookings where id = p_booking_id;
  if not found or p_date is null then return; end if;
  select opening_date into v_open from public.booking_settings limit 1;
  if p_date < greatest(coalesce(v_open, p_date), v_now_paris::date) then return; end if;
  select coalesce(margin_before_minutes, 0), coalesce(margin_after_minutes, 0) into v_mb, v_ma from public.travel_settings limit 1;
  v_dur := coalesce(b.service_duration_minutes, 60);
  v_step := v_dur + 15;
  v_ranges := work_ranges(p_date);
  foreach r in array v_ranges loop
    t := lower(r);
    while t + v_dur <= upper(r) loop
      if (p_date + make_interval(mins => t)) > v_now_paris + interval '60 minutes'
         and not exists (
           select 1 from public.bookings o
            where o.id <> b.id and o.date = p_date
              and o.status in ('PENDING', 'CONFIRMED', 'IN_PROGRESS', 'COMPLETED')
              and tsrange(o.date + o.start_time, o.date + o.start_time + make_interval(mins => coalesce(o.service_duration_minutes, 60)))
                  && tsrange(p_date + make_interval(mins => t), p_date + make_interval(mins => t + v_dur)))
         and not exists (
           select 1 from public.external_busy_blocks x
             join public.calendar_blocking_sources s on s.id = x.source_id and s.is_blocking
            where tstzrange(x.starts_at, x.ends_at)
                  && tstzrange(((p_date + make_interval(mins => t)) at time zone 'Europe/Paris') - make_interval(mins => coalesce(v_ma, 0)),
                               ((p_date + make_interval(mins => t + v_dur)) at time zone 'Europe/Paris') + make_interval(mins => coalesce(v_mb, 0))))
      then
        return next (time '00:00' + make_interval(mins => t));
      end if;
      t := t + v_step;
    end loop;
  end loop;
end $$;
revoke execute on function public.booking_free_slots(uuid, date) from public, anon, authenticated;

-- Le site lit les mêmes horaires (affichage des créneaux).
create or replace function public.get_public_booking_settings()
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object('opening_date', opening_date, 'booking_horizon_days', booking_horizon_days, 'work_hours', work_hours)
    from booking_settings where id = 1
$$;
revoke all on function public.get_public_booking_settings() from public;
grant execute on function public.get_public_booking_settings() to anon, authenticated;

-- =====================================================================
-- 2) Régime de TVA : confirmation explicite avant toute facture définitive
-- =====================================================================
alter table public.company_settings
  add column if not exists vat_regime_confirmed_at timestamptz,
  add column if not exists vat_regime_confirmed_by uuid;

-- Toute modification du régime ou du taux annule la confirmation
-- (sauf si elle passe par admin_confirm_vat_regime).
create or replace function public.company_vat_confirmation_guard()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if coalesce(current_setting('app.vat_confirm', true), '') <> 'on'
     and (NEW.vat_regime is distinct from OLD.vat_regime or NEW.default_vat_rate is distinct from OLD.default_vat_rate) then
    NEW.vat_regime_confirmed_at := null; NEW.vat_regime_confirmed_by := null;
  end if;
  return NEW;
end $$;
drop trigger if exists trg_company_vat_confirmation on public.company_settings;
create trigger trg_company_vat_confirmation before update on public.company_settings
  for each row execute function public.company_vat_confirmation_guard();

create or replace function public.admin_confirm_vat_regime(p_regime text, p_rate numeric)
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'Accès réservé à l''administration.' using errcode = '42501'; end if;
  if p_regime not in ('franchise_base', 'assujetti') then raise exception 'Régime de TVA inconnu.'; end if;
  if p_regime = 'assujetti' and (p_rate is null or p_rate not in (5.5, 10, 20)) then
    raise exception 'Taux de TVA par défaut requis (5,5 %%, 10 %% ou 20 %%).';
  end if;
  perform set_config('app.vat_confirm', 'on', true);
  update company_settings set vat_regime = p_regime, default_vat_rate = case when p_regime = 'assujetti' then p_rate else null end,
         vat_regime_confirmed_at = now(), vat_regime_confirmed_by = auth.uid(), updated_at = now()
   where id = 1;
  if not found then raise exception 'Informations entreprise introuvables.'; end if;
  insert into audit_logs (actor_user_id, action, entity, entity_id) values (auth.uid(), 'vat_regime_confirmed', 'company_settings', null);
  return jsonb_build_object('ok', true, 'vat_regime', p_regime, 'default_vat_rate', case when p_regime = 'assujetti' then p_rate end);
end $$;
revoke all on function public.admin_confirm_vat_regime(text, numeric) from public, anon;
grant execute on function public.admin_confirm_vat_regime(text, numeric) to authenticated;

-- Facturation définitive : identique à 0077 + régime de TVA confirmé.
create or replace function public.company_billing_ready()
returns boolean language sql stable security definer set search_path = public as $$
  select coalesce((
    select nullif(trim(coalesce(legal_name, trade_name, '')), '') is not null
       and nullif(trim(coalesce(owner_name, '')), '') is not null
       and nullif(trim(coalesce(address_line1, '')), '') is not null
       and nullif(trim(coalesce(postal_code, '')), '') is not null
       and nullif(trim(coalesce(city, '')), '') is not null
       and coalesce(siret, '') ~ '^[0-9]{14}$'
       and vat_regime is not null
       and (vat_regime = 'franchise_base' or nullif(trim(coalesce(vat_number, '')), '') is not null)
       and nullif(trim(coalesce(insurance_company, '')), '') is not null
       and nullif(trim(coalesce(insurance_contract_number, '')), '') is not null
       and nullif(trim(coalesce(mediator_name, '')), '') is not null
       and vat_regime_confirmed_at is not null
    from company_settings where id = 1), false);
$$;
revoke all on function public.company_billing_ready() from public, anon;
grant execute on function public.company_billing_ready() to authenticated, service_role;

-- =====================================================================
-- 3) Réglages, journal, propositions
-- =====================================================================
create table if not exists public.eva_settings (
  id integer primary key default 1 check (id = 1),
  enabled boolean not null default true,
  agents jsonb not null default '{"planning": true, "devis": true, "factures": true}'::jsonb,
  daily_command_limit integer not null default 500 check (daily_command_limit between 10 and 5000),
  updated_at timestamptz not null default now(),
  updated_by uuid
);
insert into public.eva_settings (id) values (1) on conflict (id) do nothing;
alter table public.eva_settings enable row level security;
drop policy if exists "eva_settings: admin read" on public.eva_settings;
create policy "eva_settings: admin read" on public.eva_settings for select to authenticated using (public.is_admin());

create table if not exists public.eva_journal (
  id bigserial primary key,
  created_at timestamptz not null default now(),
  actor_user_id uuid,
  command text check (char_length(command) <= 300),
  intent text not null,
  agent text,
  outcome text not null check (outcome in ('ok', 'empty', 'refused', 'error', 'proposed', 'confirmed', 'cancelled', 'failed', 'settings')),
  detail jsonb not null default '{}'::jsonb
);
create index if not exists eva_journal_actor_time on public.eva_journal (actor_user_id, created_at desc);
alter table public.eva_journal enable row level security;
drop policy if exists "eva_journal: admin read" on public.eva_journal;
create policy "eva_journal: admin read" on public.eva_journal for select to authenticated using (public.is_admin());

create table if not exists public.eva_proposals (
  id uuid primary key default gen_random_uuid(),
  created_at timestamptz not null default now(),
  created_by uuid,
  kind text not null check (kind in ('quote_draft', 'invoice_draft', 'reschedule', 'booking_confirm', 'invoice_issue', 'invoice_payment')),
  level integer not null check (level in (2, 3)),
  agent text not null,
  title text not null,
  consequences text[] not null default '{}',
  payload jsonb not null,
  entity_key text not null,
  idem_key text not null unique,
  status text not null default 'PENDING' check (status in ('PENDING', 'EXECUTED', 'CANCELLED', 'FAILED', 'EXPIRED')),
  expires_at timestamptz not null default now() + interval '24 hours',
  decided_at timestamptz,
  decided_by uuid,
  result jsonb,
  error text
);
-- Un seul dossier en cours de proposition à la fois (pas de modifications concurrentes).
create unique index if not exists eva_proposals_one_pending_per_entity on public.eva_proposals (entity_key) where status = 'PENDING';
alter table public.eva_proposals enable row level security;
drop policy if exists "eva_proposals: admin read" on public.eva_proposals;
create policy "eva_proposals: admin read" on public.eva_proposals for select to authenticated using (public.is_admin());
-- Aucune politique d'écriture : uniquement via les fonctions ci-dessous.

create or replace function public._eva_log(p_command text, p_intent text, p_agent text, p_outcome text, p_detail jsonb)
returns void language sql security definer set search_path = public as $$
  insert into eva_journal (actor_user_id, command, intent, agent, outcome, detail)
  values (auth.uid(), left(p_command, 300), p_intent, p_agent, p_outcome, coalesce(p_detail, '{}'::jsonb))
$$;

-- Garde commune : administrateur, EVA et agent activés, débit raisonnable.
create or replace function public._eva_guard(p_agent text)
returns void language plpgsql security definer set search_path = public as $$
declare s eva_settings;
begin
  if auth.uid() is null or not is_admin() then raise exception 'EVA est réservée à l''administrateur.' using errcode = '42501'; end if;
  select * into s from eva_settings where id = 1;
  if not coalesce(s.enabled, false) then raise exception 'EVA_DESACTIVEE'; end if;
  if p_agent is not null and coalesce((s.agents ->> p_agent)::boolean, false) is not true then raise exception 'AGENT_DESACTIVE:%', p_agent; end if;
  if (select count(*) from eva_journal where actor_user_id = auth.uid() and created_at > now() - interval '1 minute') >= 60 then
    raise exception 'TROP_DE_DEMANDES';
  end if;
  if (select count(*) from eva_journal where actor_user_id = auth.uid() and created_at > date_trunc('day', now())) >= s.daily_command_limit then
    raise exception 'LIMITE_JOURNALIERE';
  end if;
end $$;

-- =====================================================================
-- 4) Agents (lecture seule)
-- =====================================================================
create or replace function public._eva_client_name(p_client uuid, p_user uuid, p_guest text)
returns text language sql stable security definer set search_path = public as $$
  select coalesce(
    (select nullif(trim(coalesce(first_name, '') || ' ' || coalesce(last_name, '')), '') from clients where id = p_client),
    (select nullif(trim(coalesce(first_name, '') || ' ' || coalesce(last_name, '')), '') from customer_profiles where user_id = p_user),
    nullif(trim(p_guest), ''), 'Client non renseigné')
$$;

create or replace function public._eva_min(t time) returns integer language sql immutable as $$
  select extract(hour from t)::int * 60 + extract(minute from t)::int
$$;
create or replace function public._eva_hhmm(m integer) returns text language sql immutable as $$
  select lpad((m / 60)::text, 2, '0') || ':' || lpad((m % 60)::text, 2, '0')
$$;

-- Montant en euros au format français (« 1 234,50 € »), indépendant de la locale du serveur.
create or replace function public._eva_eur(p_cents numeric) returns text language sql immutable as $$
  select case when coalesce(p_cents, 0) < 0 then '−' else '' end
      || regexp_replace(split_part(t, '.', 1), '(\d)(?=(\d{3})+$)', '\1 ', 'g') || ',' || split_part(t, '.', 2) || ' €'
    from (select to_char(abs(coalesce(p_cents, 0)) / 100.0, 'FM999999999990.00') t) x
$$;

-- ---------- Agent Planning ----------
create or replace function public._eva_agenda(p_date date)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_margin int := coalesce((select travel_margin_minutes from booking_settings where id = 1), 30); v_items jsonb; v_blocks jsonb; v_warn jsonb := '[]'::jsonb;
  rec record; prev_end int; prev_ref text;
begin
  select coalesce(jsonb_agg(x order by x->>'start'), '[]'::jsonb) into v_items from (
    select jsonb_build_object(
      'booking_id', b.id, 'reference', b.reference, 'status', b.status,
      'start', _eva_hhmm(_eva_min(b.start_time)), 'end', _eva_hhmm(_eva_min(b.start_time) + coalesce(b.service_duration_minutes, 60)),
      'duration_minutes', coalesce(b.service_duration_minutes, 60),
      'service', coalesce((select name from service_packs where id = b.service_pack_id), (select name from services where id = b.service_id), 'Intervention'),
      'client', _eva_client_name(b.client_id, b.customer_user_id, b.guest_name),
      'phone', coalesce((select phone from clients where id = b.client_id), b.guest_phone),
      'address', coalesce(nullif(trim(case when c.city is not null and position(lower(c.city) in lower(coalesce(c.address, ''))) > 0 then c.address
                                         else coalesce(c.address, '') || ' ' || coalesce(c.postal_code, '') || ' ' || coalesce(c.city, '') end), ''), b.guest_address),
      'distance_km', b.one_way_distance_km,
      'within_hours', is_slot_within_business_hours(b.date, b.start_time, coalesce(b.service_duration_minutes, 60))) x
    from bookings b left join clients c on c.id = b.client_id
    where b.date = p_date and b.status in ('PENDING', 'CONFIRMED', 'IN_PROGRESS', 'COMPLETED')) s;

  for rec in select b.reference, _eva_min(b.start_time) s, _eva_min(b.start_time) + coalesce(b.service_duration_minutes, 60) e
               from bookings b where b.date = p_date and b.status in ('PENDING', 'CONFIRMED', 'IN_PROGRESS', 'COMPLETED') order by b.start_time loop
    if prev_end is not null then
      if rec.s < prev_end then
        v_warn := v_warn || jsonb_build_object('type', 'chevauchement', 'message', 'Chevauchement entre ' || prev_ref || ' et ' || rec.reference || '.');
      elsif rec.s - prev_end < v_margin then
        v_warn := v_warn || jsonb_build_object('type', 'trajet', 'message', 'Seulement ' || (rec.s - prev_end) || ' min entre ' || prev_ref || ' et ' || rec.reference || ' (marge de trajet réglée : ' || v_margin || ' min).');
      end if;
    end if;
    prev_end := greatest(coalesce(prev_end, rec.e), rec.e); prev_ref := rec.reference;
  end loop;

  select coalesce(jsonb_agg(jsonb_build_object('start', to_char(x.starts_at at time zone 'Europe/Paris', 'HH24:MI'), 'end', to_char(x.ends_at at time zone 'Europe/Paris', 'HH24:MI'),
           'all_day', x.is_all_day, 'source', s.display_name) order by x.starts_at), '[]'::jsonb) into v_blocks
    from external_busy_blocks x join calendar_blocking_sources s on s.id = x.source_id and s.is_blocking
   where tstzrange(x.starts_at, x.ends_at) && tstzrange((p_date::timestamp) at time zone 'Europe/Paris', ((p_date + 1)::timestamp) at time zone 'Europe/Paris');

  return jsonb_build_object('date', p_date, 'interventions', v_items, 'busy_blocks', v_blocks, 'warnings', v_warn,
    'work_ranges', (select coalesce(jsonb_agg(_eva_hhmm(lower(r)) || '–' || _eva_hhmm(upper(r))), '[]'::jsonb) from unnest(work_ranges(p_date)) r),
    'travel_margin_minutes', v_margin);
end $$;

-- Créneau libre = dans les horaires, hors réservations (marge de trajet
-- avant/après), hors indisponibilités Apple bloquantes, après l'ouverture.
create or replace function public._eva_slot_free(p_date date, p_start int, p_dur int, p_ignore uuid default null)
returns boolean language plpgsql stable security definer set search_path = public as $$
declare v_margin int := coalesce((select travel_margin_minutes from booking_settings where id = 1), 30);
  v_open date := coalesce((select opening_date from booking_settings where id = 1), p_date);
  v_now timestamp := now() at time zone 'Europe/Paris';
begin
  if p_date < v_open or (p_date + make_interval(mins => p_start)) < v_now + interval '60 minutes' then return false; end if;
  if not exists (select 1 from unnest(work_ranges(p_date)) r where p_start >= lower(r) and p_start + p_dur <= upper(r)) then return false; end if;
  if exists (select 1 from bookings o where o.date = p_date and o.id is distinct from p_ignore
               and o.status in ('PENDING', 'CONFIRMED', 'IN_PROGRESS', 'COMPLETED')
               and int4range(_eva_min(o.start_time) - v_margin, _eva_min(o.start_time) + coalesce(o.service_duration_minutes, 60) + v_margin)
                   && int4range(p_start, p_start + p_dur)) then return false; end if;
  if exists (select 1 from external_busy_blocks x join calendar_blocking_sources s on s.id = x.source_id and s.is_blocking
              where tstzrange(x.starts_at, x.ends_at) && tstzrange((p_date + make_interval(mins => p_start)) at time zone 'Europe/Paris',
                                                                  (p_date + make_interval(mins => p_start + p_dur)) at time zone 'Europe/Paris')) then return false; end if;
  return true;
end $$;

create or replace function public._eva_free_slots(p_from date, p_to date, p_duration int)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare d date; r int4range; t int; v_out jsonb := '[]'::jsonb; v_day int; v_total int := 0; v_dur int := greatest(15, least(coalesce(p_duration, 60), 480));
begin
  if p_to < p_from or p_to - p_from > 31 then raise exception 'PERIODE_INVALIDE'; end if;
  d := p_from;
  while d <= p_to and v_total < 24 loop
    v_day := 0;
    foreach r in array work_ranges(d) loop
      t := lower(r);
      while t + v_dur <= upper(r) and v_day < 3 loop
        if _eva_slot_free(d, t, v_dur) then
          v_out := v_out || jsonb_build_object('date', d, 'start', _eva_hhmm(t), 'end', _eva_hhmm(t + v_dur));
          v_day := v_day + 1; v_total := v_total + 1; t := t + v_dur + 30;
        else t := t + 15; end if;
      end loop;
    end loop;
    d := d + 1;
  end loop;
  return jsonb_build_object('from', p_from, 'to', p_to, 'duration_minutes', v_dur, 'slots', v_out,
    'travel_margin_minutes', coalesce((select travel_margin_minutes from booking_settings where id = 1), 30));
end $$;

create or replace function public._eva_conflicts(p_from date, p_to date)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_out jsonb := '[]'::jsonb; v_margin int := coalesce((select travel_margin_minutes from booking_settings where id = 1), 30); rec record;
begin
  if p_to < p_from or p_to - p_from > 62 then raise exception 'PERIODE_INVALIDE'; end if;
  -- Chevauchements et marges de trajet insuffisantes entre deux interventions.
  for rec in
    select a.date, a.reference ra, b.reference rb,
           _eva_min(b.start_time) - (_eva_min(a.start_time) + coalesce(a.service_duration_minutes, 60)) gap
      from bookings a join bookings b on a.date = b.date and a.id <> b.id
       and (a.start_time, a.id) < (b.start_time, b.id)
     where a.date between p_from and p_to
       and a.status in ('PENDING', 'CONFIRMED', 'IN_PROGRESS') and b.status in ('PENDING', 'CONFIRMED', 'IN_PROGRESS')
       and _eva_min(b.start_time) - (_eva_min(a.start_time) + coalesce(a.service_duration_minutes, 60)) < v_margin
     order by a.date, a.start_time
  loop
    v_out := v_out || jsonb_build_object('date', rec.date, 'type', case when rec.gap < 0 then 'chevauchement' else 'trajet' end,
      'message', case when rec.gap < 0 then 'Chevauchement entre ' || rec.ra || ' et ' || rec.rb || '.'
                      else 'Seulement ' || rec.gap || ' min entre ' || rec.ra || ' et ' || rec.rb || ' (marge réglée : ' || v_margin || ' min).' end);
  end loop;
  -- Rendez-vous hors horaires ou sur une indisponibilité Apple.
  for rec in
    select b.date, b.reference,
           not is_slot_within_business_hours(b.date, b.start_time, coalesce(b.service_duration_minutes, 60)) off_hours,
           exists (select 1 from external_busy_blocks x join calendar_blocking_sources s on s.id = x.source_id and s.is_blocking
                    where tstzrange(x.starts_at, x.ends_at) && tstzrange((b.date + b.start_time) at time zone 'Europe/Paris',
                          (b.date + b.start_time + make_interval(mins => coalesce(b.service_duration_minutes, 60))) at time zone 'Europe/Paris')) busy
      from bookings b
     where b.date between p_from and p_to and b.status in ('PENDING', 'CONFIRMED', 'IN_PROGRESS')
  loop
    if rec.off_hours then v_out := v_out || jsonb_build_object('date', rec.date, 'type', 'horaires', 'message', rec.reference || ' est en dehors des horaires de travail.'); end if;
    if rec.busy then v_out := v_out || jsonb_build_object('date', rec.date, 'type', 'calendrier', 'message', rec.reference || ' chevauche une indisponibilité de votre calendrier Apple.'); end if;
  end loop;
  return jsonb_build_object('from', p_from, 'to', p_to, 'conflicts', v_out);
end $$;

-- ---------- Recherche de client ----------
create or replace function public._eva_norm(p text) returns text language sql immutable as $$
  select lower(translate(coalesce(p, ''), 'ÀÂÄÁÃÉÈÊËÍÌÎÏÓÒÔÖÕÚÙÛÜÇàâäáãéèêëíìîïóòôöõúùûüçÿ', 'AAAAAEEEEIIIIOOOOOUUUUCaaaaaeeeeiiiiooooouuuucy'))
$$;
create or replace function public._eva_find_client(p_query text)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_q text := trim(coalesce(p_query, '')); v_words text[]; v_digits text;
begin
  if char_length(v_q) < 2 then return jsonb_build_object('query', v_q, 'clients', '[]'::jsonb); end if;
  v_words := regexp_split_to_array(_eva_norm(regexp_replace(v_q, '\m(monsieur|madame|mme|mlle|m\.|mr)\M', '', 'gi')), '\s+');
  v_words := array(select w from unnest(v_words) w where char_length(w) >= 2);
  v_digits := regexp_replace(v_q, '\D', '', 'g');
  return jsonb_build_object('query', v_q, 'clients', coalesce((
    select jsonb_agg(jsonb_build_object('client_id', c.id, 'name', trim(coalesce(c.first_name, '') || ' ' || coalesce(c.last_name, '')),
             'city', c.city, 'phone', c.phone, 'email', c.email, 'type', c.client_type) order by c.last_name, c.first_name)
      from (select * from clients c
             where c.merged_into is null
               and ((cardinality(v_words) > 0 and not exists (select 1 from unnest(v_words) w
                      where position(w in _eva_norm(coalesce(c.first_name, '') || ' ' || coalesce(c.last_name, '') || ' ' || coalesce(c.email, '') || ' ' || coalesce(c.city, ''))) = 0))
                 or (char_length(v_digits) >= 6 and regexp_replace(coalesce(c.phone, ''), '\D', '', 'g') like '%' || v_digits || '%'))
             limit 8) c), '[]'::jsonb));
end $$;

-- ---------- Agent Devis ----------
-- Chiffrage déterministe : uniquement les prix ENREGISTRÉS du catalogue.
-- Prix « à partir de » ou « sur devis » : jamais de montant inventé, la
-- ligne est signalée comme information manquante.
create or replace function public._eva_quote_estimate(p_service_query text, p_client_id uuid, p_distance_km numeric)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_words text[]; v_matches jsonb; v_missing jsonb := '[]'::jsonb; v_dist numeric := p_distance_km; v_travel int; v_client jsonb;
  v_best record; v_count int;
begin
  v_words := array(select w from unnest(regexp_split_to_array(_eva_norm(p_service_query), '[^a-z0-9]+')) w
                    where char_length(w) >= 3 and w not in ('pour', 'les', 'des', 'une', 'avec', 'sur', 'chez', 'remplacer', 'remplacement', 'devis', 'prepare', 'preparer', 'monsieur', 'madame'));
  -- Prestations et forfaits actifs dont le nom contient le plus de mots demandés.
  select coalesce(jsonb_agg(z.m order by z.score desc, z.m->>'label'), '[]'::jsonb), count(*) into v_matches, v_count from (
    select jsonb_build_object('kind', k.kind, 'id', k.id, 'label', k.label, 'mode', k.mode,
             -- Prix communiqué uniquement s'il est fixe ; sinon null (à chiffrer).
             'price_cents', case when k.mode = 'FIXED' then k.price end, 'duration_minutes', k.dur) m, k.score
      from (select y.*, (select count(*) from unnest(v_words) w where position(w in _eva_norm(y.label)) > 0) score
              from (select 'service' kind, s.id, s.name label, coalesce(s.price_display_mode, 'FIXED') mode, s.base_price_cents price, s.duration_minutes dur
                      from services s where s.is_active
                    union all
                    select 'pack', p.id, s.name || ' — ' || p.name, 'FIXED', p.price_cents, p.duration_minutes
                      from service_packs p join services s on s.id = p.service_id where p.is_active and s.is_active) y) k
     -- Au moins la moitié des mots significatifs (« pose de panneaux solaires » ne
     -- correspond pas à « Pose baignoire » sur le seul mot « pose »).
     where cardinality(v_words) > 0 and k.score > 0 and k.score * 2 >= cardinality(v_words)
     order by k.score desc, k.label limit 5) z;

  if p_client_id is not null then
    select jsonb_build_object('client_id', c.id, 'name', trim(coalesce(c.first_name, '') || ' ' || coalesce(c.last_name, '')), 'city', c.city, 'type', c.client_type)
      into v_client from clients c where c.id = p_client_id;
    if v_dist is null then
      select b.one_way_distance_km into v_dist from bookings b where b.client_id = p_client_id and b.one_way_distance_km is not null order by b.created_at desc limit 1;
    end if;
  end if;
  if v_count = 0 then v_missing := v_missing || to_jsonb('Prestation introuvable dans le catalogue : hors catalogue, à chiffrer par vous.'::text); end if;
  if v_dist is null then
    v_missing := v_missing || to_jsonb('Distance du chantier inconnue : frais de déplacement non calculés.'::text);
  else
    select fee_cents into v_travel from compute_travel_fee_cents(v_dist, false);
  end if;
  if p_client_id is null then v_missing := v_missing || to_jsonb('Client non identifié.'::text); end if;
  return jsonb_build_object('query', p_service_query, 'client', v_client, 'matches', v_matches, 'distance_km', v_dist,
    'travel_fee_cents', v_travel, 'missing', v_missing, 'supplies_note', 'Aucun prix de fourniture n''est déduit : le catalogue fournisseurs est la seule source.');
end $$;

create or replace function public._eva_quotes_pending()
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'drafts', coalesce((select jsonb_agg(jsonb_build_object('quote_id', q.id, 'reference', q.reference, 'title', q.title, 'total_cents', q.total_cents,
                 'client', _eva_client_name(q.client_id, q.customer_user_id, null), 'age_days', (current_date - q.created_at::date)) order by q.created_at)
                 from quotes q where q.status = 'DRAFT'), '[]'::jsonb),
    'sent', coalesce((select jsonb_agg(jsonb_build_object('quote_id', q.id, 'reference', q.reference, 'total_cents', q.total_cents,
                 'client', _eva_client_name(q.client_id, q.customer_user_id, null), 'sent_days', (current_date - q.sent_at::date)) order by q.sent_at)
                 from quotes q where q.status = 'SENT'), '[]'::jsonb),
    'accepted_not_invoiced', coalesce((select jsonb_agg(jsonb_build_object('quote_id', q.id, 'reference', q.reference, 'total_cents', q.total_cents,
                 'client', _eva_client_name(q.client_id, q.customer_user_id, null)) order by q.accepted_at)
                 from quotes q where q.status = 'ACCEPTED' and not exists (select 1 from invoices i where i.quote_id = q.id and i.status <> 'CANCELLED')), '[]'::jsonb))
$$;

-- ---------- Agent Factures ----------
create or replace function public._eva_invoices_todo()
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'billing_ready', company_billing_ready(),
    'vat_regime', (select vat_regime from company_settings where id = 1),
    'default_vat_rate', (select default_vat_rate from company_settings where id = 1),
    'vat_confirmed', (select vat_regime_confirmed_at is not null from company_settings where id = 1),
    'completed_without_invoice', coalesce((select jsonb_agg(jsonb_build_object('booking_id', b.id, 'reference', b.reference, 'date', b.date,
                 'client', _eva_client_name(b.client_id, b.customer_user_id, b.guest_name),
                 'service', coalesce((select name from services where id = b.service_id), 'Intervention'), 'total_cents', b.total_cents,
                 'report', (select i.report_status from interventions i where i.booking_id = b.id order by i.created_at desc limit 1)) order by b.date)
                 from bookings b where b.status = 'COMPLETED'
                   and not exists (select 1 from invoices i where i.booking_id = b.id and i.status <> 'CANCELLED')
                   and not exists (select 1 from quotes q join invoices i on i.quote_id = q.id and i.status <> 'CANCELLED' where q.booking_id = b.id)), '[]'::jsonb),
    'accepted_quotes_without_invoice', coalesce((select jsonb_agg(jsonb_build_object('quote_id', q.id, 'reference', q.reference, 'total_cents', q.total_cents,
                 'client', _eva_client_name(q.client_id, q.customer_user_id, null)))
                 from quotes q where q.status = 'ACCEPTED' and not exists (select 1 from invoices i where i.quote_id = q.id and i.status <> 'CANCELLED')), '[]'::jsonb),
    'drafts', coalesce((select jsonb_agg(jsonb_build_object('invoice_id', i.id, 'reference', i.reference, 'total_cents', i.total_cents,
                 'lines', (select count(*) from invoice_lines l where l.invoice_id = i.id),
                 'client', _eva_client_name(i.client_id, i.customer_user_id, null)) order by i.created_at)
                 from invoices i where i.status = 'DRAFT'), '[]'::jsonb),
    'unpaid', coalesce((select jsonb_agg(x order by x->>'due_date') from (
                 select jsonb_build_object('invoice_id', i.id, 'reference', i.reference, 'total_cents', i.total_cents,
                   'paid_cents', coalesce((select sum(p.amount_cents) from invoice_payments p where p.invoice_id = i.id), 0),
                   'due_date', i.due_date, 'overdue', i.due_date is not null and i.due_date < current_date,
                   'client', _eva_client_name(i.client_id, i.customer_user_id, null)) x
                   from invoices i where i.status = 'ISSUED'
                    and coalesce((select sum(p.amount_cents) from invoice_payments p where p.invoice_id = i.id), 0) < i.total_cents) u), '[]'::jsonb))
$$;

-- ---------- Points d'attention ----------
create or replace function public._eva_attention()
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v jsonb := '[]'::jsonb; n int; co company_settings; inv jsonb := _eva_invoices_todo(); conf jsonb;
begin
  select * into co from company_settings where id = 1;
  select count(*) into n from bookings where status = 'PENDING' and date >= current_date;
  if n > 0 then v := v || jsonb_build_object('level', 'action', 'agent', 'planning', 'message', n || ' demande(s) de rendez-vous à confirmer.'); end if;
  conf := _eva_conflicts(current_date, current_date + 14) -> 'conflicts';
  if jsonb_array_length(conf) > 0 then v := v || jsonb_build_object('level', 'alerte', 'agent', 'planning', 'message', jsonb_array_length(conf) || ' conflit(s) de planning dans les 15 prochains jours.'); end if;
  select count(*) into n from bookings where calendar_sync_status = 'ERROR' and date >= current_date;
  if n > 0 then v := v || jsonb_build_object('level', 'alerte', 'agent', 'planning', 'message', n || ' rendez-vous non synchronisé(s) avec Apple Calendar.'); end if;
  if jsonb_array_length(inv -> 'completed_without_invoice') > 0 then v := v || jsonb_build_object('level', 'action', 'agent', 'factures', 'message', jsonb_array_length(inv -> 'completed_without_invoice') || ' intervention(s) terminée(s) sans facture.'); end if;
  if jsonb_array_length(inv -> 'accepted_quotes_without_invoice') > 0 then v := v || jsonb_build_object('level', 'action', 'agent', 'factures', 'message', jsonb_array_length(inv -> 'accepted_quotes_without_invoice') || ' devis accepté(s) non facturé(s).'); end if;
  select count(*) into n from jsonb_array_elements(inv -> 'unpaid') x where (x ->> 'overdue')::boolean;
  if n > 0 then v := v || jsonb_build_object('level', 'alerte', 'agent', 'factures', 'message', n || ' facture(s) échue(s) non réglée(s).'); end if;
  select count(*) into n from quotes where status = 'SENT' and sent_at < now() - interval '14 days';
  if n > 0 then v := v || jsonb_build_object('level', 'action', 'agent', 'devis', 'message', n || ' devis envoyé(s) sans réponse depuis plus de 14 jours.'); end if;
  if co.vat_regime_confirmed_at is null then v := v || jsonb_build_object('level', 'reglage', 'agent', 'factures', 'message', 'Régime de TVA à confirmer avant toute facture définitive.'); end if;
  if not company_billing_ready() then v := v || jsonb_build_object('level', 'reglage', 'agent', 'factures', 'message', 'Informations légales de l''entreprise incomplètes : aucune facture définitive possible.'); end if;
  return jsonb_build_object('items', v);
end $$;

-- ---------- Finances d'une période (montants enregistrés uniquement) ----------
create or replace function public._eva_finance(p_from date, p_to date)
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object('from', p_from, 'to', p_to,
    'invoiced_count', (select count(*) from invoices where status in ('ISSUED', 'PAID') and (issued_at at time zone 'Europe/Paris')::date between p_from and p_to),
    'invoiced_cents', coalesce((select sum(total_cents) from invoices where status in ('ISSUED', 'PAID') and (issued_at at time zone 'Europe/Paris')::date between p_from and p_to), 0),
    'collected_cents', coalesce((select sum(amount_cents) from invoice_payments where paid_on between p_from and p_to), 0),
    'credit_notes_cents', coalesce((select sum(amount_cents) from credit_notes where (created_at at time zone 'Europe/Paris')::date between p_from and p_to), 0),
    'outstanding_cents', coalesce((select sum(i.total_cents - coalesce((select sum(p.amount_cents) from invoice_payments p where p.invoice_id = i.id), 0)) from invoices i where i.status = 'ISSUED'), 0),
    'quotes_sent_count', (select count(*) from quotes where (sent_at at time zone 'Europe/Paris')::date between p_from and p_to),
    'quotes_accepted_count', (select count(*) from quotes where (accepted_at at time zone 'Europe/Paris')::date between p_from and p_to),
    'completed_count', (select count(*) from bookings where status = 'COMPLETED' and date between p_from and p_to),
    'drafts_count', (select count(*) from invoices where status = 'DRAFT'))
$$;

-- ---------- Devis d'un client ----------
create or replace function public._eva_client_quotes(p_query text, p_client uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_clients jsonb; v_id uuid := p_client;
begin
  if v_id is null then
    v_clients := _eva_find_client(p_query) -> 'clients';
    if jsonb_array_length(v_clients) <> 1 then return jsonb_build_object('query', p_query, 'clients', v_clients, 'quotes', '[]'::jsonb); end if;
    v_id := (v_clients -> 0 ->> 'client_id')::uuid;
  end if;
  return jsonb_build_object('query', p_query,
    'clients', (select jsonb_agg(jsonb_build_object('client_id', c.id, 'name', trim(coalesce(c.first_name, '') || ' ' || coalesce(c.last_name, '')), 'city', c.city)) from clients c where c.id = v_id),
    'quotes', coalesce((select jsonb_agg(jsonb_build_object('quote_id', q.id, 'reference', q.reference, 'title', q.title, 'status', q.status, 'total_cents', q.total_cents,
                  'created_at', q.created_at, 'sent_at', q.sent_at, 'accepted_at', q.accepted_at) order by q.created_at desc)
                  from quotes q where q.client_id = v_id or q.customer_user_id = (select user_id from clients where id = v_id)), '[]'::jsonb));
end $$;

-- ---------- Clients qui attendent une réponse ----------
create or replace function public._eva_awaiting()
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'booking_requests', coalesce((select jsonb_agg(jsonb_build_object('booking_id', b.id, 'reference', b.reference, 'date', b.date, 'start', _eva_hhmm(_eva_min(b.start_time)),
         'client', _eva_client_name(b.client_id, b.customer_user_id, b.guest_name),
         'service', coalesce((select name from services where id = b.service_id), 'Intervention'), 'waiting_days', current_date - b.created_at::date) order by b.created_at)
         from bookings b where b.status = 'PENDING' and b.date >= current_date), '[]'::jsonb),
    'callbacks', coalesce((select jsonb_agg(jsonb_build_object('id', h.id, 'name', coalesce(nullif(trim(h.contact_name), ''), 'Visiteur'), 'phone', h.contact_phone,
         'reason', h.reason, 'waiting_days', current_date - h.created_at::date) order by h.created_at)
         from ai_human_requests h where h.admin_viewed_at is null), '[]'::jsonb))
$$;

-- ---------- Dernière intervention terminée ----------
create or replace function public._eva_last_intervention()
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce((select jsonb_build_object('booking_id', b.id, 'reference', b.reference, 'date', b.date,
      'client', _eva_client_name(b.client_id, b.customer_user_id, b.guest_name),
      'service', coalesce((select name from services where id = b.service_id), 'Intervention'), 'total_cents', b.total_cents,
      'invoice', (select jsonb_build_object('invoice_id', i.id, 'reference', i.reference, 'status', i.status) from invoices i where i.booking_id = b.id and i.status <> 'CANCELLED' limit 1))
    from bookings b where b.status = 'COMPLETED' order by b.date desc, b.start_time desc limit 1), 'null'::jsonb)
$$;

-- ---------- Registre des capacités d'EVA ----------
create table if not exists public.eva_tools (
  key text primary key,
  agent text not null,
  label text not null,
  level integer not null check (level between 1 and 4),
  status text not null check (status in ('disponible', 'a_developper', 'non_realisable')),
  example text,
  note text,
  sort integer not null default 100
);
alter table public.eva_tools enable row level security;
drop policy if exists "eva_tools: admin read" on public.eva_tools;
create policy "eva_tools: admin read" on public.eva_tools for select to authenticated using (public.is_admin());
insert into public.eva_tools (key, agent, label, level, status, example, note, sort) values
  ('agenda', 'planning', 'Voir le planning d''un jour', 1, 'disponible', 'Montre-moi mon planning de demain', null, 10),
  ('free_slots', 'planning', 'Trouver des créneaux libres', 1, 'disponible', 'Mes disponibilités la semaine prochaine', null, 11),
  ('conflicts', 'planning', 'Détecter les conflits de planning', 1, 'disponible', 'Vérifie les conflits de planning', null, 12),
  ('reschedule', 'planning', 'Déplacer un rendez-vous', 3, 'disponible', 'Décale mon premier rendez-vous de demain', 'Client prévenu, Apple Calendar mis à jour', 13),
  ('booking_confirm', 'planning', 'Confirmer une demande de rendez-vous', 3, 'disponible', 'Quels clients attendent une réponse ?', 'Client prévenu, ajout à Apple Calendar', 14),
  ('awaiting', 'planning', 'Clients qui attendent une réponse', 1, 'disponible', 'Quels clients attendent une réponse ?', null, 15),
  ('find_client', 'clients', 'Trouver une fiche client', 1, 'disponible', 'Trouve la fiche de Monsieur Martin', null, 20),
  ('client_quotes', 'devis', 'Retrouver les devis d''un client', 1, 'disponible', 'Retrouve le dernier devis de Monsieur Dupont', null, 21),
  ('quote_estimate', 'devis', 'Chiffrer à partir du catalogue', 1, 'disponible', 'Prépare un devis pour un mitigeur lavabo de Monsieur Dupont', 'Prix fixes du catalogue uniquement', 22),
  ('quote_draft', 'devis', 'Créer un brouillon de devis', 2, 'disponible', null, 'Jamais envoyé automatiquement', 23),
  ('quotes_pending', 'devis', 'Devis en attente', 1, 'disponible', 'Quels devis sont en attente ?', null, 24),
  ('invoices_todo', 'factures', 'Factures à préparer et impayés', 1, 'disponible', 'Prépare les factures des interventions terminées', null, 30),
  ('invoice_draft', 'factures', 'Créer un brouillon de facture', 2, 'disponible', 'Prépare une facture pour ma dernière intervention', null, 31),
  ('invoice_issue', 'factures', 'Émettre une facture définitive', 3, 'disponible', null, 'Numéro définitif attribué par le serveur ; identité légale et TVA confirmée requises', 32),
  ('invoice_payment', 'factures', 'Enregistrer un paiement reçu', 3, 'disponible', null, 'Montant, moyen et date saisis par vous', 33),
  ('finance', 'factures', 'Chiffre d''affaires d''une période', 1, 'disponible', 'Combien j''ai facturé cette semaine ?', null, 34),
  ('attention', 'eva', 'Points d''attention', 1, 'disponible', 'Quels dossiers nécessitent mon attention ?', null, 40),
  ('brief', 'eva', 'Synthèse de la journée', 1, 'disponible', 'Résume ma journée', null, 41),
  ('dev_request', 'eva', 'Noter une demande d''évolution du site', 2, 'disponible', 'Ajoute une nouvelle fonctionnalité à mon site : …', 'Transmise plus tard à un agent de développement séparé, jamais déployée automatiquement', 42),
  ('client_create', 'clients', 'Créer ou modifier un client', 3, 'a_developper', 'Crée un nouveau client', 'Aucune fonction serveur de création côté administration aujourd''hui', 50),
  ('service_create', 'catalogue', 'Ajouter ou modifier une prestation', 3, 'a_developper', 'Ajoute une prestation de remplacement de siphon', 'Brouillon puis publication confirmée', 51),
  ('quote_send', 'devis', 'Envoyer un devis au client', 3, 'a_developper', 'Envoie le devis de Monsieur Dupont', 'Aujourd''hui mis à jour directement depuis le navigateur', 52),
  ('booking_cancel', 'planning', 'Annuler ou refuser un rendez-vous', 3, 'a_developper', 'Annule le rendez-vous de demain matin', 'Motif obligatoire', 53),
  ('booking_create', 'planning', 'Créer un rendez-vous pour un client', 3, 'a_developper', 'Prends rendez-vous pour Monsieur Martin jeudi', null, 54),
  ('equipment', 'clients', 'Équipements et adresses des clients', 2, 'a_developper', null, null, 55),
  ('reports', 'interventions', 'Comptes rendus, photos, fiches d''intervention', 2, 'a_developper', null, 'Les photos restent ajoutées depuis la fiche', 56),
  ('settings', 'eva', 'Paramètres (tarifs, déplacement, SMS)', 3, 'a_developper', null, null, 57),
  ('free_conversation', 'eva', 'Conversation totalement libre', 1, 'non_realisable', null, 'Demande un modèle de langage (payant ou matériel dédié)', 90),
  ('background_listening', 'eva', 'Écoute « Dis EVA » application fermée ou écran verrouillé', 1, 'non_realisable', null, 'Impossible pour une application web sur iPhone ; utilisez « Dis Siri, EVA »', 91)
on conflict (key) do update set agent = excluded.agent, label = excluded.label, level = excluded.level, status = excluded.status,
  example = excluded.example, note = excluded.note, sort = excluded.sort;

-- ---------- Demandes d'évolution (file transmise plus tard à un agent de développement séparé) ----------
create table if not exists public.eva_dev_requests (
  id uuid primary key default gen_random_uuid(),
  created_at timestamptz not null default now(),
  created_by uuid,
  request text not null check (char_length(request) between 5 and 1000),
  status text not null default 'NOUVELLE' check (status in ('NOUVELLE', 'EN_ANALYSE', 'PROPOSEE', 'REFUSEE', 'TERMINEE')),
  note text
);
alter table public.eva_dev_requests enable row level security;
drop policy if exists "eva_dev_requests: admin read" on public.eva_dev_requests;
create policy "eva_dev_requests: admin read" on public.eva_dev_requests for select to authenticated using (public.is_admin());

create or replace function public.eva_add_dev_request(p_request text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_id uuid; v_txt text := trim(coalesce(p_request, ''));
begin
  perform _eva_guard(null);
  if char_length(v_txt) < 5 then raise exception 'Décrivez la fonctionnalité souhaitée.'; end if;
  select id into v_id from eva_dev_requests where request = left(v_txt, 1000) and created_at > now() - interval '1 day';
  if v_id is null then
    insert into eva_dev_requests (created_by, request) values (auth.uid(), left(v_txt, 1000)) returning id into v_id;
  end if;
  perform _eva_log(left(v_txt, 300), 'dev_request', null, 'proposed', jsonb_build_object('request_id', v_id));
  return jsonb_build_object('ok', true, 'request_id', v_id);
end $$;

-- =====================================================================
-- 5) Point d'entrée unique (orchestrateur serveur)
-- =====================================================================
create or replace function public.eva_run(p_intent text, p_args jsonb default '{}'::jsonb, p_command text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_agent text; v_data jsonb; v_empty boolean := false; a jsonb := coalesce(p_args, '{}'::jsonb);
  v_today date := (now() at time zone 'Europe/Paris')::date;
  v_date date; v_from date; v_to date;
begin
  v_agent := case p_intent when 'agenda' then 'planning' when 'free_slots' then 'planning' when 'conflicts' then 'planning'
                           when 'quote_estimate' then 'devis' when 'quotes_pending' then 'devis' when 'find_client' then null
                           when 'invoices_todo' then 'factures' when 'attention' then null when 'brief' then null
                           when 'finance' then 'factures' when 'client_quotes' then 'devis' when 'awaiting' then 'planning'
                           when 'last_intervention' then 'factures' when 'capabilities' then null
                           else 'inconnu' end;
  if v_agent = 'inconnu' then raise exception 'INTENTION_INCONNUE'; end if;
  perform _eva_guard(v_agent);
  begin
    v_date := coalesce(nullif(a ->> 'date', '')::date, v_today);
    v_from := coalesce(nullif(a ->> 'from', '')::date, v_today);
    v_to := coalesce(nullif(a ->> 'to', '')::date, v_from + 6);
  exception when others then raise exception 'DATE_INVALIDE';
  end;
  if p_intent = 'agenda' then
    v_data := _eva_agenda(v_date); v_empty := jsonb_array_length(v_data -> 'interventions') = 0;
  elsif p_intent = 'free_slots' then
    v_data := _eva_free_slots(v_from, v_to, nullif(a ->> 'duration', '')::int); v_empty := jsonb_array_length(v_data -> 'slots') = 0;
  elsif p_intent = 'conflicts' then
    v_data := _eva_conflicts(v_from, v_to); v_empty := jsonb_array_length(v_data -> 'conflicts') = 0;
  elsif p_intent = 'find_client' then
    v_data := _eva_find_client(a ->> 'query'); v_empty := jsonb_array_length(v_data -> 'clients') = 0;
  elsif p_intent = 'quote_estimate' then
    if nullif(a ->> 'client_id', '') is not null then
      v_data := jsonb_build_object('clients', (select jsonb_agg(jsonb_build_object('client_id', c.id, 'name', trim(coalesce(c.first_name, '') || ' ' || coalesce(c.last_name, '')), 'city', c.city))
                                                 from clients c where c.id = (a ->> 'client_id')::uuid and c.merged_into is null));
      if v_data -> 'clients' is null or v_data -> 'clients' = 'null'::jsonb then raise exception 'Client introuvable.'; end if;
    else
      v_data := jsonb_build_object('clients', _eva_find_client(a ->> 'client') -> 'clients');
    end if;
    v_data := v_data || _eva_quote_estimate(a ->> 'service',
      case when jsonb_array_length(v_data -> 'clients') = 1 then (v_data -> 'clients' -> 0 ->> 'client_id')::uuid end,
      nullif(a ->> 'distance_km', '')::numeric);
    v_empty := jsonb_array_length(v_data -> 'matches') = 0;
  elsif p_intent = 'quotes_pending' then
    v_data := _eva_quotes_pending();
    v_empty := jsonb_array_length(v_data -> 'drafts') + jsonb_array_length(v_data -> 'sent') + jsonb_array_length(v_data -> 'accepted_not_invoiced') = 0;
  elsif p_intent = 'invoices_todo' then
    v_data := _eva_invoices_todo();
    v_empty := jsonb_array_length(v_data -> 'completed_without_invoice') + jsonb_array_length(v_data -> 'accepted_quotes_without_invoice')
             + jsonb_array_length(v_data -> 'drafts') + jsonb_array_length(v_data -> 'unpaid') = 0;
  elsif p_intent = 'attention' then
    v_data := _eva_attention(); v_empty := jsonb_array_length(v_data -> 'items') = 0;
  elsif p_intent = 'finance' then
    v_data := _eva_finance(v_from, coalesce(nullif(a ->> 'to', '')::date, v_today));
  elsif p_intent = 'client_quotes' then
    v_data := _eva_client_quotes(a ->> 'client', nullif(a ->> 'client_id', '')::uuid);
    v_empty := jsonb_array_length(coalesce(v_data -> 'clients', '[]'::jsonb)) = 0;
  elsif p_intent = 'awaiting' then
    v_data := _eva_awaiting(); v_empty := jsonb_array_length(v_data -> 'booking_requests') + jsonb_array_length(v_data -> 'callbacks') = 0;
  elsif p_intent = 'last_intervention' then
    v_data := _eva_last_intervention(); v_empty := v_data = 'null'::jsonb;
  elsif p_intent = 'capabilities' then
    v_data := jsonb_build_object('tools', (select jsonb_agg(jsonb_build_object('key', key, 'agent', agent, 'label', label, 'level', level, 'status', status, 'example', example, 'note', note) order by sort) from eva_tools));
  elsif p_intent = 'brief' then
    v_data := jsonb_build_object('agenda', case when (select (agents ->> 'planning')::boolean from eva_settings where id = 1) then _eva_agenda(v_date) end,
      'quotes', case when (select (agents ->> 'devis')::boolean from eva_settings where id = 1) then _eva_quotes_pending() end,
      'invoices', case when (select (agents ->> 'factures')::boolean from eva_settings where id = 1) then _eva_invoices_todo() end,
      'attention', _eva_attention());
  end if;
  perform _eva_log(p_command, p_intent, v_agent, case when v_empty then 'empty' else 'ok' end, jsonb_build_object('args', a));
  return jsonb_build_object('ok', true, 'intent', p_intent, 'agent', v_agent, 'empty', v_empty, 'data', v_data,
    'generated_at', now());
end $$;

-- =====================================================================
-- 6) Propositions : préparer → confirmer explicitement → exécuter
-- =====================================================================
create or replace function public.eva_propose(p_kind text, p_payload jsonb, p_idem_key text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_agent text; v_level int; v_title text; v_cons text[]; v_entity text; v_payload jsonb := coalesce(p_payload, '{}'::jsonb);
  v_existing eva_proposals; v_id uuid; b bookings; q quotes; v_date date; v_start int; v_lines jsonb := '[]'::jsonb; v_total int := 0;
  v_item jsonb; v_price int; v_label text; v_travel int; v_client clients;
begin
  if coalesce(char_length(p_idem_key), 0) not between 8 and 80 then raise exception 'CLE_INVALIDE'; end if;
  v_agent := case p_kind when 'invoice_draft' then 'factures' when 'quote_draft' then 'devis' when 'reschedule' then 'planning'
                         when 'booking_confirm' then 'planning' when 'invoice_issue' then 'factures' when 'invoice_payment' then 'factures' else null end;
  if v_agent is null then raise exception 'PROPOSITION_INCONNUE'; end if;
  perform _eva_guard(v_agent);
  -- Même demande renvoyée deux fois : la même proposition est rendue.
  select * into v_existing from eva_proposals where idem_key = p_idem_key;
  if found then return jsonb_build_object('ok', true, 'proposal_id', v_existing.id, 'status', v_existing.status, 'duplicate', true); end if;
  update eva_proposals set status = 'EXPIRED' where status = 'PENDING' and expires_at < now();

  if p_kind = 'invoice_draft' then
    v_level := 2;
    if v_payload ->> 'source' = 'booking' then
      select * into b from bookings where id = (v_payload ->> 'id')::uuid;
      if not found then raise exception 'Rendez-vous introuvable.'; end if;
      if b.status <> 'COMPLETED' then raise exception 'Seul un rendez-vous terminé peut être facturé.'; end if;
      v_entity := 'booking:' || b.id; v_title := 'Brouillon de facture — intervention ' || b.reference;
    elsif v_payload ->> 'source' = 'quote' then
      select * into q from quotes where id = (v_payload ->> 'id')::uuid;
      if not found then raise exception 'Devis introuvable.'; end if;
      if q.status <> 'ACCEPTED' then raise exception 'Seul un devis accepté peut être facturé.'; end if;
      v_entity := 'quote:' || q.id; v_title := 'Brouillon de facture — devis ' || q.reference;
    else raise exception 'Source de facture inconnue.'; end if;
    v_payload := jsonb_build_object('source', v_payload ->> 'source', 'id', v_payload ->> 'id');
    v_cons := array['Crée un BROUILLON de facture à partir des montants enregistrés.', 'Aucun numéro définitif, aucune émission, aucun envoi au client.',
                    'TVA selon le régime enregistré (' || coalesce((select vat_regime from company_settings where id = 1), 'non renseigné') || ', ' ||
                    case when (select vat_regime_confirmed_at from company_settings where id = 1) is null then 'NON confirmé' else 'confirmé' end || ').'];

  elsif p_kind = 'quote_draft' then
    v_level := 2;
    select * into v_client from clients where id = (v_payload ->> 'client_id')::uuid and merged_into is null;
    if not found then raise exception 'Client introuvable.'; end if;
    if jsonb_typeof(v_payload -> 'items') <> 'array' or jsonb_array_length(v_payload -> 'items') not between 1 and 10 then raise exception 'Lignes invalides.'; end if;
    for v_item in select value from jsonb_array_elements(v_payload -> 'items') loop
      if v_item ->> 'kind' = 'pack' then
        select s.name || ' — ' || p.name, p.price_cents into v_label, v_price from service_packs p join services s on s.id = p.service_id
         where p.id = (v_item ->> 'id')::uuid and p.is_active;
      else
        select s.name, case when coalesce(s.price_display_mode, 'FIXED') = 'FIXED' then s.base_price_cents end into v_label, v_price
          from services s where s.id = (v_item ->> 'id')::uuid and s.is_active;
      end if;
      if v_label is null then raise exception 'Prestation introuvable.'; end if;
      if v_price is null then raise exception 'La prestation « % » n''a pas de prix fixe enregistré : à chiffrer par vous.', v_label; end if;
      v_lines := v_lines || jsonb_build_object('kind', coalesce(v_item ->> 'kind', 'service'), 'id', v_item ->> 'id', 'label', v_label, 'price_cents', v_price);
      v_total := v_total + v_price; v_label := null; v_price := null;
    end loop;
    if nullif(v_payload ->> 'distance_km', '') is not null then select fee_cents into v_travel from compute_travel_fee_cents((v_payload ->> 'distance_km')::numeric, false); end if;
    v_entity := 'client-quote:' || v_client.id;
    v_title := 'Brouillon de devis — ' || trim(coalesce(v_client.first_name, '') || ' ' || coalesce(v_client.last_name, ''));
    v_payload := jsonb_build_object('client_id', v_client.id, 'lines', v_lines, 'subtotal_cents', v_total, 'travel_fee_cents', coalesce(v_travel, 0),
      'travel_known', v_travel is not null, 'total_cents', v_total + coalesce(v_travel, 0));
    v_cons := array['Crée un BROUILLON de devis de ' || _eva_eur(v_total + coalesce(v_travel, 0)) || ' (tarifs du catalogue).',
                    case when v_travel is null then 'Déplacement non chiffré (distance inconnue) : à compléter avant envoi.' else 'Déplacement inclus : ' || _eva_eur(v_travel) || '.' end,
                    'Rien n''est envoyé au client : l''envoi reste à faire depuis la rubrique Devis.'];

  elsif p_kind = 'reschedule' then
    v_level := 3;
    select * into b from bookings where id = (v_payload ->> 'booking_id')::uuid;
    if not found then raise exception 'Rendez-vous introuvable.'; end if;
    if b.status not in ('PENDING', 'CONFIRMED') then raise exception 'Ce rendez-vous ne peut pas être déplacé.'; end if;
    v_date := (v_payload ->> 'date')::date; v_start := eva_hhmm_minutes(v_payload ->> 'start');
    if v_date is null or v_start is null then raise exception 'Date ou heure invalide.'; end if;
    if not _eva_slot_free(v_date, v_start, coalesce(b.service_duration_minutes, 60), b.id) then
      raise exception 'Créneau indisponible (horaires, autre rendez-vous, marge de trajet ou calendrier Apple).';
    end if;
    v_entity := 'booking:' || b.id;
    v_payload := jsonb_build_object('booking_id', b.id, 'date', v_date, 'start', _eva_hhmm(v_start),
      'old_date', b.date, 'old_start', _eva_hhmm(_eva_min(b.start_time)));
    v_title := 'Déplacer ' || b.reference || ' au ' || to_char(v_date, 'DD/MM/YYYY') || ' à ' || _eva_hhmm(v_start);
    v_cons := array['Le rendez-vous du ' || to_char(b.date, 'DD/MM/YYYY') || ' à ' || _eva_hhmm(_eva_min(b.start_time)) || ' est déplacé.',
                    'Le client est prévenu par e-mail (notification existante).',
                    'L''événement Apple Calendar est mis à jour, sans doublon.'];
  end if;

  if p_kind = 'booking_confirm' then
    v_level := 3;
    select * into b from bookings where id = (v_payload ->> 'booking_id')::uuid;
    if not found then raise exception 'Rendez-vous introuvable.'; end if;
    if b.status <> 'PENDING' then raise exception 'Cette demande a déjà été traitée.'; end if;
    v_entity := 'booking:' || b.id;
    v_payload := jsonb_build_object('booking_id', b.id);
    v_title := 'Confirmer ' || b.reference || ' — ' || _eva_client_name(b.client_id, b.customer_user_id, b.guest_name) || ', ' || to_char(b.date, 'DD/MM/YYYY') || ' à ' || _eva_hhmm(_eva_min(b.start_time));
    v_cons := array['Le rendez-vous passe en « Confirmé ».', 'Le client reçoit l''e-mail « Rendez-vous confirmé ».', 'Le rendez-vous est ajouté à Apple Calendar.'];
  elsif p_kind = 'invoice_issue' then
    v_level := 3;
    if not company_billing_ready() then raise exception 'Facturation définitive impossible : informations légales ou régime de TVA à compléter.'; end if;
    select reference, total_cents into v_label, v_price from invoices where id = (v_payload ->> 'invoice_id')::uuid;
    if not exists (select 1 from invoices where id = (v_payload ->> 'invoice_id')::uuid and status = 'DRAFT') then raise exception 'Seul un brouillon de facture peut être émis.'; end if;
    v_entity := 'invoice:' || (v_payload ->> 'invoice_id');
    v_payload := jsonb_build_object('invoice_id', v_payload ->> 'invoice_id', 'due_date', nullif(v_payload ->> 'due_date', ''));
    v_title := 'Émettre la facture ' || coalesce(v_label, '') || ' (' || _eva_eur(coalesce(v_price, 0)) || ')';
    v_cons := array['Un numéro définitif FAC-… est attribué par le serveur.', 'La facture devient définitive : elle ne pourra plus être modifiée, seulement corrigée par un avoir.',
                    'Elle n''est pas envoyée automatiquement par EVA.'];
  elsif p_kind = 'invoice_payment' then
    v_level := 3;
    if not exists (select 1 from invoices where id = (v_payload ->> 'invoice_id')::uuid and status = 'ISSUED') then raise exception 'Seule une facture émise peut recevoir un paiement.'; end if;
    if coalesce((v_payload ->> 'amount_cents')::int, 0) <= 0 then raise exception 'Montant du paiement requis.'; end if;
    if coalesce(v_payload ->> 'method', '') not in ('virement', 'cheque', 'especes', 'carte', 'autre') then raise exception 'Moyen de paiement requis.'; end if;
    if nullif(v_payload ->> 'paid_on', '') is null or (v_payload ->> 'paid_on')::date > (now() at time zone 'Europe/Paris')::date then raise exception 'Date de paiement invalide.'; end if;
    v_entity := 'invoice:' || (v_payload ->> 'invoice_id');
    v_payload := jsonb_build_object('invoice_id', v_payload ->> 'invoice_id', 'amount_cents', (v_payload ->> 'amount_cents')::int, 'method', v_payload ->> 'method', 'paid_on', v_payload ->> 'paid_on');
    v_title := 'Enregistrer un paiement de ' || _eva_eur((v_payload ->> 'amount_cents')::int) || ' (' || (v_payload ->> 'method') || ', ' || to_char((v_payload ->> 'paid_on')::date, 'DD/MM/YYYY') || ')';
    v_cons := array['Le paiement est ajouté à la facture ' || (select reference from invoices where id = (v_payload ->> 'invoice_id')::uuid) || '.',
                    'Il doit correspondre à un règlement réellement reçu.', 'La facture passe en « Payée » si le total est atteint.'];
  end if;

  begin
    insert into eva_proposals (created_by, kind, level, agent, title, consequences, payload, entity_key, idem_key)
    values (auth.uid(), p_kind, v_level, v_agent, v_title, v_cons, v_payload, v_entity, p_idem_key) returning id into v_id;
  exception when unique_violation then
    raise exception 'DOSSIER_OCCUPE';
  end;
  perform _eva_log(null, 'propose:' || p_kind, v_agent, 'proposed', jsonb_build_object('proposal_id', v_id, 'entity', v_entity));
  return jsonb_build_object('ok', true, 'proposal_id', v_id, 'status', 'PENDING', 'level', v_level, 'title', v_title,
    'consequences', to_jsonb(v_cons), 'payload', v_payload);
end $$;

-- Confirmation : bouton explicite de l'interface (p_confirm = true), jamais
-- un texte libre. Idempotente : une proposition exécutée renvoie son résultat.
create or replace function public.eva_confirm_proposal(p_id uuid, p_confirm boolean)
returns jsonb language plpgsql security definer set search_path = public as $$
declare p eva_proposals; v_result jsonb; v_inv uuid; v_quote uuid; v_line jsonb; v_pos int := 0;
begin
  if p_confirm is not true then raise exception 'CONFIRMATION_REQUISE'; end if;
  if auth.uid() is null or not is_admin() then raise exception 'EVA est réservée à l''administrateur.' using errcode = '42501'; end if;
  select * into p from eva_proposals where id = p_id for update;
  if not found then raise exception 'Proposition introuvable.'; end if;
  if p.status = 'EXECUTED' then return jsonb_build_object('ok', true, 'status', 'EXECUTED', 'result', p.result, 'duplicate', true); end if;
  if p.status <> 'PENDING' then raise exception 'Proposition déjà traitée (%).', p.status; end if;
  if p.expires_at < now() then
    update eva_proposals set status = 'EXPIRED' where id = p.id;
    return jsonb_build_object('ok', false, 'status', 'EXPIRED', 'error', 'Proposition expirée : relancez la demande.');
  end if;
  perform _eva_guard(p.agent);
  perform pg_advisory_xact_lock(hashtext(p.entity_key));
  begin
    if p.kind = 'invoice_draft' then
      v_inv := admin_create_invoice(p.payload ->> 'source', (p.payload ->> 'id')::uuid);
      v_result := jsonb_build_object('invoice_id', v_inv, 'reference', (select reference from invoices where id = v_inv));
    elsif p.kind = 'quote_draft' then
      insert into quotes (client_id, reference, status, title, subtotal_cents, travel_fee_cents, total_cents)
      values ((p.payload ->> 'client_id')::uuid, 'DV-EVA-' || upper(substr(replace(p.id::text, '-', ''), 1, 8)), 'DRAFT',
              (select string_agg(x ->> 'label', ' + ') from jsonb_array_elements(p.payload -> 'lines') x),
              (p.payload ->> 'subtotal_cents')::int, (p.payload ->> 'travel_fee_cents')::int, (p.payload ->> 'total_cents')::int)
      returning id into v_quote;
      insert into quote_options (quote_id, label, description, supply_cents, labor_cents, sort_order)
      values (v_quote, 'Proposition', (select string_agg(x ->> 'label' || ' : ' || _eva_eur((x ->> 'price_cents')::int), E'\n')
                                         from jsonb_array_elements(p.payload -> 'lines') x),
              0, (p.payload ->> 'subtotal_cents')::int, 0);
      update quotes set selected_option_id = (select id from quote_options where quote_id = v_quote limit 1) where id = v_quote;
      v_result := jsonb_build_object('quote_id', v_quote, 'reference', (select reference from quotes where id = v_quote));
    elsif p.kind = 'reschedule' then
      if not _eva_slot_free((p.payload ->> 'date')::date, eva_hhmm_minutes(p.payload ->> 'start'),
                            coalesce((select service_duration_minutes from bookings where id = (p.payload ->> 'booking_id')::uuid), 60),
                            (p.payload ->> 'booking_id')::uuid) then
        raise exception 'Le créneau n''est plus disponible.';
      end if;
      perform admin_reschedule_booking((p.payload ->> 'booking_id')::uuid, (p.payload ->> 'date')::date, (p.payload ->> 'start')::time);
      v_result := jsonb_build_object('booking_id', p.payload ->> 'booking_id', 'date', p.payload ->> 'date', 'start', p.payload ->> 'start');
    elsif p.kind = 'booking_confirm' then
      -- Même opération que le bouton « Confirmer » de l'administration :
      -- les déclencheurs existants envoient l'e-mail et créent l'événement Apple.
      update bookings set status = 'CONFIRMED' where id = (p.payload ->> 'booking_id')::uuid and status = 'PENDING';
      if not found then raise exception 'Cette demande a déjà été traitée.'; end if;
      v_result := jsonb_build_object('booking_id', p.payload ->> 'booking_id', 'confirmed', true);
    elsif p.kind = 'invoice_issue' then
      v_result := jsonb_build_object('invoice_id', p.payload ->> 'invoice_id',
        'reference', admin_issue_invoice((p.payload ->> 'invoice_id')::uuid, nullif(p.payload ->> 'due_date', '')::date), 'issued', true);
    elsif p.kind = 'invoice_payment' then
      perform admin_record_invoice_payment((p.payload ->> 'invoice_id')::uuid, (p.payload ->> 'amount_cents')::int, p.payload ->> 'method', (p.payload ->> 'paid_on')::date, 'Enregistré via EVA');
      v_result := jsonb_build_object('invoice_id', p.payload ->> 'invoice_id', 'payment', true,
        'invoice_status', (select status from invoices where id = (p.payload ->> 'invoice_id')::uuid));
    end if;
  exception when others then
    update eva_proposals set status = 'FAILED', error = left(sqlerrm, 300), decided_at = now(), decided_by = auth.uid() where id = p.id;
    perform _eva_log(null, 'confirm:' || p.kind, p.agent, 'failed', jsonb_build_object('proposal_id', p.id, 'error', left(sqlerrm, 300)));
    return jsonb_build_object('ok', false, 'status', 'FAILED', 'error', left(sqlerrm, 300));
  end;
  update eva_proposals set status = 'EXECUTED', result = v_result, decided_at = now(), decided_by = auth.uid() where id = p.id;
  perform _eva_log(null, 'confirm:' || p.kind, p.agent, 'confirmed', jsonb_build_object('proposal_id', p.id, 'result', v_result));
  return jsonb_build_object('ok', true, 'status', 'EXECUTED', 'result', v_result);
end $$;

create or replace function public.eva_cancel_proposal(p_id uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare p eva_proposals;
begin
  if auth.uid() is null or not is_admin() then raise exception 'EVA est réservée à l''administrateur.' using errcode = '42501'; end if;
  update eva_proposals set status = 'CANCELLED', decided_at = now(), decided_by = auth.uid() where id = p_id and status = 'PENDING' returning * into p;
  if not found then raise exception 'Proposition introuvable ou déjà traitée.'; end if;
  perform _eva_log(null, 'cancel:' || p.kind, p.agent, 'cancelled', jsonb_build_object('proposal_id', p.id));
  return jsonb_build_object('ok', true, 'status', 'CANCELLED');
end $$;

-- Tableau de bord EVA : réglages, propositions récentes, historique.
create or replace function public.eva_overview()
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null or not is_admin() then raise exception 'EVA est réservée à l''administrateur.' using errcode = '42501'; end if;
  update eva_proposals set status = 'EXPIRED' where status = 'PENDING' and expires_at < now();
  return jsonb_build_object(
    'settings', (select jsonb_build_object('enabled', enabled, 'agents', agents, 'daily_command_limit', daily_command_limit) from eva_settings where id = 1),
    'work', (select jsonb_build_object('work_hours', work_hours, 'travel_margin_minutes', travel_margin_minutes) from booking_settings where id = 1),
    'vat', (select jsonb_build_object('vat_regime', vat_regime, 'default_vat_rate', default_vat_rate, 'confirmed_at', vat_regime_confirmed_at,
                                      'billing_ready', company_billing_ready()) from company_settings where id = 1),
    'proposals', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'kind', kind, 'level', level, 'agent', agent, 'title', title,
                    'consequences', consequences, 'status', status, 'created_at', created_at, 'expires_at', expires_at, 'result', result, 'error', error)
                    order by created_at desc) from (select * from eva_proposals order by created_at desc limit 30) x), '[]'::jsonb),
    'journal', coalesce((select jsonb_agg(jsonb_build_object('at', created_at, 'command', command, 'intent', intent, 'agent', agent, 'outcome', outcome)
                    order by created_at desc) from (select * from eva_journal where actor_user_id = auth.uid() order by created_at desc limit 40) j), '[]'::jsonb),
    'today_count', (select count(*) from eva_journal where actor_user_id = auth.uid() and created_at > date_trunc('day', now())),
    'dev_requests', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'at', created_at, 'request', request, 'status', status) order by created_at desc)
                    from (select * from eva_dev_requests order by created_at desc limit 20) d), '[]'::jsonb));
end $$;

create or replace function public.eva_set_settings(p_enabled boolean, p_agents jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null or not is_admin() then raise exception 'EVA est réservée à l''administrateur.' using errcode = '42501'; end if;
  if p_agents is null or jsonb_typeof(p_agents) <> 'object'
     or exists (select 1 from jsonb_object_keys(p_agents) k where k not in ('planning', 'devis', 'factures'))
     or exists (select 1 from jsonb_each(p_agents) e where jsonb_typeof(e.value) <> 'boolean') then raise exception 'Réglage des agents invalide.'; end if;
  update eva_settings set enabled = coalesce(p_enabled, enabled), agents = agents || p_agents, updated_at = now(), updated_by = auth.uid() where id = 1;
  perform _eva_log(null, 'settings', null, 'settings', jsonb_build_object('enabled', p_enabled, 'agents', p_agents));
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.admin_set_work_hours(p_work_hours jsonb, p_travel_margin integer)
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null or not is_admin() then raise exception 'Accès réservé à l''administration.' using errcode = '42501'; end if;
  if not work_hours_valid(p_work_hours) then raise exception 'Horaires invalides : plages HH:MM croissantes, sans chevauchement, entre 05:00 et 22:00.'; end if;
  if p_travel_margin is null or p_travel_margin not between 0 and 180 then raise exception 'Marge de trajet entre 0 et 180 minutes.'; end if;
  update booking_settings set work_hours = p_work_hours, travel_margin_minutes = p_travel_margin, updated_at = now(), updated_by = auth.uid() where id = 1;
  insert into audit_logs (actor_user_id, action, entity, entity_id) values (auth.uid(), 'work_hours_updated', 'booking_settings', null);
  return jsonb_build_object('ok', true);
end $$;

-- =====================================================================
-- Droits : fonctions internes inaccessibles, points d'entrée réservés
-- aux comptes connectés (le rôle administrateur est revérifié dedans).
-- =====================================================================
do $$
declare f text;
begin
  foreach f in array array[
    'public._eva_log(text, text, text, text, jsonb)', 'public._eva_guard(text)', 'public._eva_client_name(uuid, uuid, text)',
    'public._eva_agenda(date)', 'public._eva_slot_free(date, integer, integer, uuid)', 'public._eva_free_slots(date, date, integer)',
    'public._eva_conflicts(date, date)', 'public._eva_find_client(text)', 'public._eva_quote_estimate(text, uuid, numeric)',
    'public._eva_quotes_pending()', 'public._eva_invoices_todo()', 'public._eva_attention()', 'public.company_vat_confirmation_guard()',
    'public._eva_finance(date, date)', 'public._eva_eur(numeric)', 'public._eva_client_quotes(text, uuid)', 'public._eva_awaiting()', 'public._eva_last_intervention()'] loop
    execute 'revoke all on function ' || f || ' from public, anon, authenticated';
  end loop;
  foreach f in array array[
    'public.eva_run(text, jsonb, text)', 'public.eva_propose(text, jsonb, text)', 'public.eva_confirm_proposal(uuid, boolean)',
    'public.eva_cancel_proposal(uuid)', 'public.eva_overview()', 'public.eva_set_settings(boolean, jsonb)', 'public.admin_set_work_hours(jsonb, integer)',
    'public.eva_add_dev_request(text)'] loop
    execute 'revoke all on function ' || f || ' from public, anon';
    execute 'grant execute on function ' || f || ' to authenticated';
  end loop;
end $$;
