-- RETOUR ARRIÈRE des migrations EVA 0135, 0136, 0137 et 0138 (production).
-- À n'exécuter QUE sur décision explicite, en un seul bloc (transaction).
-- Effet : la base revient exactement à son état d'avant EVA :
--   * les 4 fonctions existantes modifiées par 0135 retrouvent leur définition
--     et leurs droits de PRODUCTION (relevés le 11/10/2026) ;
--   * les colonnes, contraintes et le déclencheur ajoutés sont retirés ;
--   * les objets propres à EVA (tables eva_*, fonctions) sont supprimés.
-- Aucune donnée existante (clients, réservations, devis, factures, parrainage)
-- n'est touchée. Seules les données d'EVA (journal, propositions, appareils
-- Siri, horaires saisis dans EVA, confirmation de TVA) sont perdues : les
-- exporter avant si besoin (voir PLAN_EVA_PRODUCTION.md, étape « Sauvegarde »).
begin;

-- 1) Fonctions d'EVA
do $$ declare f regprocedure; begin for f in select p.oid::regprocedure from pg_proc p join pg_namespace s on s.oid = p.pronamespace where s.nspname = 'public' and p.proname = '_eva_agenda' loop execute 'drop function ' || f || ' cascade'; end loop; end $$;
do $$ declare f regprocedure; begin for f in select p.oid::regprocedure from pg_proc p join pg_namespace s on s.oid = p.pronamespace where s.nspname = 'public' and p.proname = '_eva_agenda_range' loop execute 'drop function ' || f || ' cascade'; end loop; end $$;
do $$ declare f regprocedure; begin for f in select p.oid::regprocedure from pg_proc p join pg_namespace s on s.oid = p.pronamespace where s.nspname = 'public' and p.proname = '_eva_attention' loop execute 'drop function ' || f || ' cascade'; end loop; end $$;
do $$ declare f regprocedure; begin for f in select p.oid::regprocedure from pg_proc p join pg_namespace s on s.oid = p.pronamespace where s.nspname = 'public' and p.proname = '_eva_awaiting' loop execute 'drop function ' || f || ' cascade'; end loop; end $$;
do $$ declare f regprocedure; begin for f in select p.oid::regprocedure from pg_proc p join pg_namespace s on s.oid = p.pronamespace where s.nspname = 'public' and p.proname = '_eva_booking_brief' loop execute 'drop function ' || f || ' cascade'; end loop; end $$;
do $$ declare f regprocedure; begin for f in select p.oid::regprocedure from pg_proc p join pg_namespace s on s.oid = p.pronamespace where s.nspname = 'public' and p.proname = '_eva_catalog' loop execute 'drop function ' || f || ' cascade'; end loop; end $$;
do $$ declare f regprocedure; begin for f in select p.oid::regprocedure from pg_proc p join pg_namespace s on s.oid = p.pronamespace where s.nspname = 'public' and p.proname = '_eva_clean' loop execute 'drop function ' || f || ' cascade'; end loop; end $$;
do $$ declare f regprocedure; begin for f in select p.oid::regprocedure from pg_proc p join pg_namespace s on s.oid = p.pronamespace where s.nspname = 'public' and p.proname = '_eva_client_detail' loop execute 'drop function ' || f || ' cascade'; end loop; end $$;
do $$ declare f regprocedure; begin for f in select p.oid::regprocedure from pg_proc p join pg_namespace s on s.oid = p.pronamespace where s.nspname = 'public' and p.proname = '_eva_client_name' loop execute 'drop function ' || f || ' cascade'; end loop; end $$;
do $$ declare f regprocedure; begin for f in select p.oid::regprocedure from pg_proc p join pg_namespace s on s.oid = p.pronamespace where s.nspname = 'public' and p.proname = '_eva_client_quotes' loop execute 'drop function ' || f || ' cascade'; end loop; end $$;
do $$ declare f regprocedure; begin for f in select p.oid::regprocedure from pg_proc p join pg_namespace s on s.oid = p.pronamespace where s.nspname = 'public' and p.proname = '_eva_conflicts' loop execute 'drop function ' || f || ' cascade'; end loop; end $$;
do $$ declare f regprocedure; begin for f in select p.oid::regprocedure from pg_proc p join pg_namespace s on s.oid = p.pronamespace where s.nspname = 'public' and p.proname = '_eva_eur' loop execute 'drop function ' || f || ' cascade'; end loop; end $$;
do $$ declare f regprocedure; begin for f in select p.oid::regprocedure from pg_proc p join pg_namespace s on s.oid = p.pronamespace where s.nspname = 'public' and p.proname = '_eva_execute_ext' loop execute 'drop function ' || f || ' cascade'; end loop; end $$;
do $$ declare f regprocedure; begin for f in select p.oid::regprocedure from pg_proc p join pg_namespace s on s.oid = p.pronamespace where s.nspname = 'public' and p.proname = '_eva_ext_agent' loop execute 'drop function ' || f || ' cascade'; end loop; end $$;
do $$ declare f regprocedure; begin for f in select p.oid::regprocedure from pg_proc p join pg_namespace s on s.oid = p.pronamespace where s.nspname = 'public' and p.proname = '_eva_finance' loop execute 'drop function ' || f || ' cascade'; end loop; end $$;
do $$ declare f regprocedure; begin for f in select p.oid::regprocedure from pg_proc p join pg_namespace s on s.oid = p.pronamespace where s.nspname = 'public' and p.proname = '_eva_find_client' loop execute 'drop function ' || f || ' cascade'; end loop; end $$;
do $$ declare f regprocedure; begin for f in select p.oid::regprocedure from pg_proc p join pg_namespace s on s.oid = p.pronamespace where s.nspname = 'public' and p.proname = '_eva_free_slots' loop execute 'drop function ' || f || ' cascade'; end loop; end $$;
do $$ declare f regprocedure; begin for f in select p.oid::regprocedure from pg_proc p join pg_namespace s on s.oid = p.pronamespace where s.nspname = 'public' and p.proname = '_eva_guard' loop execute 'drop function ' || f || ' cascade'; end loop; end $$;
do $$ declare f regprocedure; begin for f in select p.oid::regprocedure from pg_proc p join pg_namespace s on s.oid = p.pronamespace where s.nspname = 'public' and p.proname = '_eva_hhmm' loop execute 'drop function ' || f || ' cascade'; end loop; end $$;
do $$ declare f regprocedure; begin for f in select p.oid::regprocedure from pg_proc p join pg_namespace s on s.oid = p.pronamespace where s.nspname = 'public' and p.proname = '_eva_invoices_list' loop execute 'drop function ' || f || ' cascade'; end loop; end $$;
do $$ declare f regprocedure; begin for f in select p.oid::regprocedure from pg_proc p join pg_namespace s on s.oid = p.pronamespace where s.nspname = 'public' and p.proname = '_eva_invoices_todo' loop execute 'drop function ' || f || ' cascade'; end loop; end $$;
do $$ declare f regprocedure; begin for f in select p.oid::regprocedure from pg_proc p join pg_namespace s on s.oid = p.pronamespace where s.nspname = 'public' and p.proname = '_eva_last_intervention' loop execute 'drop function ' || f || ' cascade'; end loop; end $$;
do $$ declare f regprocedure; begin for f in select p.oid::regprocedure from pg_proc p join pg_namespace s on s.oid = p.pronamespace where s.nspname = 'public' and p.proname = '_eva_log' loop execute 'drop function ' || f || ' cascade'; end loop; end $$;
do $$ declare f regprocedure; begin for f in select p.oid::regprocedure from pg_proc p join pg_namespace s on s.oid = p.pronamespace where s.nspname = 'public' and p.proname = '_eva_loyalty' loop execute 'drop function ' || f || ' cascade'; end loop; end $$;
do $$ declare f regprocedure; begin for f in select p.oid::regprocedure from pg_proc p join pg_namespace s on s.oid = p.pronamespace where s.nspname = 'public' and p.proname = '_eva_maintenance_due' loop execute 'drop function ' || f || ' cascade'; end loop; end $$;
do $$ declare f regprocedure; begin for f in select p.oid::regprocedure from pg_proc p join pg_namespace s on s.oid = p.pronamespace where s.nspname = 'public' and p.proname = '_eva_min' loop execute 'drop function ' || f || ' cascade'; end loop; end $$;
do $$ declare f regprocedure; begin for f in select p.oid::regprocedure from pg_proc p join pg_namespace s on s.oid = p.pronamespace where s.nspname = 'public' and p.proname = '_eva_norm' loop execute 'drop function ' || f || ' cascade'; end loop; end $$;
do $$ declare f regprocedure; begin for f in select p.oid::regprocedure from pg_proc p join pg_namespace s on s.oid = p.pronamespace where s.nspname = 'public' and p.proname = '_eva_prepare_ext' loop execute 'drop function ' || f || ' cascade'; end loop; end $$;
do $$ declare f regprocedure; begin for f in select p.oid::regprocedure from pg_proc p join pg_namespace s on s.oid = p.pronamespace where s.nspname = 'public' and p.proname = '_eva_quote_estimate' loop execute 'drop function ' || f || ' cascade'; end loop; end $$;
do $$ declare f regprocedure; begin for f in select p.oid::regprocedure from pg_proc p join pg_namespace s on s.oid = p.pronamespace where s.nspname = 'public' and p.proname = '_eva_quotes_pending' loop execute 'drop function ' || f || ' cascade'; end loop; end $$;
do $$ declare f regprocedure; begin for f in select p.oid::regprocedure from pg_proc p join pg_namespace s on s.oid = p.pronamespace where s.nspname = 'public' and p.proname = '_eva_referrals' loop execute 'drop function ' || f || ' cascade'; end loop; end $$;
do $$ declare f regprocedure; begin for f in select p.oid::regprocedure from pg_proc p join pg_namespace s on s.oid = p.pronamespace where s.nspname = 'public' and p.proname = '_eva_report' loop execute 'drop function ' || f || ' cascade'; end loop; end $$;
do $$ declare f regprocedure; begin for f in select p.oid::regprocedure from pg_proc p join pg_namespace s on s.oid = p.pronamespace where s.nspname = 'public' and p.proname = '_eva_resolve_client' loop execute 'drop function ' || f || ' cascade'; end loop; end $$;
do $$ declare f regprocedure; begin for f in select p.oid::regprocedure from pg_proc p join pg_namespace s on s.oid = p.pronamespace where s.nspname = 'public' and p.proname = '_eva_siri_read_intents' loop execute 'drop function ' || f || ' cascade'; end loop; end $$;
do $$ declare f regprocedure; begin for f in select p.oid::regprocedure from pg_proc p join pg_namespace s on s.oid = p.pronamespace where s.nspname = 'public' and p.proname = '_eva_slot_free' loop execute 'drop function ' || f || ' cascade'; end loop; end $$;
do $$ declare f regprocedure; begin for f in select p.oid::regprocedure from pg_proc p join pg_namespace s on s.oid = p.pronamespace where s.nspname = 'public' and p.proname = '_eva_stats' loop execute 'drop function ' || f || ' cascade'; end loop; end $$;
do $$ declare f regprocedure; begin for f in select p.oid::regprocedure from pg_proc p join pg_namespace s on s.oid = p.pronamespace where s.nspname = 'public' and p.proname = 'admin_confirm_vat_regime' loop execute 'drop function ' || f || ' cascade'; end loop; end $$;
do $$ declare f regprocedure; begin for f in select p.oid::regprocedure from pg_proc p join pg_namespace s on s.oid = p.pronamespace where s.nspname = 'public' and p.proname = 'admin_set_work_hours' loop execute 'drop function ' || f || ' cascade'; end loop; end $$;
do $$ declare f regprocedure; begin for f in select p.oid::regprocedure from pg_proc p join pg_namespace s on s.oid = p.pronamespace where s.nspname = 'public' and p.proname = 'company_vat_confirmation_guard' loop execute 'drop function ' || f || ' cascade'; end loop; end $$;
do $$ declare f regprocedure; begin for f in select p.oid::regprocedure from pg_proc p join pg_namespace s on s.oid = p.pronamespace where s.nspname = 'public' and p.proname = 'eva_add_dev_request' loop execute 'drop function ' || f || ' cascade'; end loop; end $$;
do $$ declare f regprocedure; begin for f in select p.oid::regprocedure from pg_proc p join pg_namespace s on s.oid = p.pronamespace where s.nspname = 'public' and p.proname = 'eva_cancel_proposal' loop execute 'drop function ' || f || ' cascade'; end loop; end $$;
do $$ declare f regprocedure; begin for f in select p.oid::regprocedure from pg_proc p join pg_namespace s on s.oid = p.pronamespace where s.nspname = 'public' and p.proname = 'eva_confirm_proposal' loop execute 'drop function ' || f || ' cascade'; end loop; end $$;
do $$ declare f regprocedure; begin for f in select p.oid::regprocedure from pg_proc p join pg_namespace s on s.oid = p.pronamespace where s.nspname = 'public' and p.proname = 'eva_device_create' loop execute 'drop function ' || f || ' cascade'; end loop; end $$;
do $$ declare f regprocedure; begin for f in select p.oid::regprocedure from pg_proc p join pg_namespace s on s.oid = p.pronamespace where s.nspname = 'public' and p.proname = 'eva_device_revoke' loop execute 'drop function ' || f || ' cascade'; end loop; end $$;
do $$ declare f regprocedure; begin for f in select p.oid::regprocedure from pg_proc p join pg_namespace s on s.oid = p.pronamespace where s.nspname = 'public' and p.proname = 'eva_devices_list' loop execute 'drop function ' || f || ' cascade'; end loop; end $$;
do $$ declare f regprocedure; begin for f in select p.oid::regprocedure from pg_proc p join pg_namespace s on s.oid = p.pronamespace where s.nspname = 'public' and p.proname = 'eva_hhmm_minutes' loop execute 'drop function ' || f || ' cascade'; end loop; end $$;
do $$ declare f regprocedure; begin for f in select p.oid::regprocedure from pg_proc p join pg_namespace s on s.oid = p.pronamespace where s.nspname = 'public' and p.proname = 'eva_overview' loop execute 'drop function ' || f || ' cascade'; end loop; end $$;
do $$ declare f regprocedure; begin for f in select p.oid::regprocedure from pg_proc p join pg_namespace s on s.oid = p.pronamespace where s.nspname = 'public' and p.proname = 'eva_propose' loop execute 'drop function ' || f || ' cascade'; end loop; end $$;
do $$ declare f regprocedure; begin for f in select p.oid::regprocedure from pg_proc p join pg_namespace s on s.oid = p.pronamespace where s.nspname = 'public' and p.proname = 'eva_query' loop execute 'drop function ' || f || ' cascade'; end loop; end $$;
do $$ declare f regprocedure; begin for f in select p.oid::regprocedure from pg_proc p join pg_namespace s on s.oid = p.pronamespace where s.nspname = 'public' and p.proname = 'eva_run' loop execute 'drop function ' || f || ' cascade'; end loop; end $$;
do $$ declare f regprocedure; begin for f in select p.oid::regprocedure from pg_proc p join pg_namespace s on s.oid = p.pronamespace where s.nspname = 'public' and p.proname = 'eva_set_settings' loop execute 'drop function ' || f || ' cascade'; end loop; end $$;
do $$ declare f regprocedure; begin for f in select p.oid::regprocedure from pg_proc p join pg_namespace s on s.oid = p.pronamespace where s.nspname = 'public' and p.proname = 'eva_siri_run' loop execute 'drop function ' || f || ' cascade'; end loop; end $$;
do $$ declare f regprocedure; begin for f in select p.oid::regprocedure from pg_proc p join pg_namespace s on s.oid = p.pronamespace where s.nspname = 'public' and p.proname = 'eva_siri_set' loop execute 'drop function ' || f || ' cascade'; end loop; end $$;
do $$ declare f regprocedure; begin for f in select p.oid::regprocedure from pg_proc p join pg_namespace s on s.oid = p.pronamespace where s.nspname = 'public' and p.proname = 'work_hours_valid' loop execute 'drop function ' || f || ' cascade'; end loop; end $$;
do $$ declare f regprocedure; begin for f in select p.oid::regprocedure from pg_proc p join pg_namespace s on s.oid = p.pronamespace where s.nspname = 'public' and p.proname = 'work_ranges' loop execute 'drop function ' || f || ' cascade'; end loop; end $$;
-- 0138 (actions préparées par Siri, réauthentification) : enveloppes et fonctions internes
do $$ declare f regprocedure; begin for f in select p.oid::regprocedure from pg_proc p join pg_namespace s on s.oid = p.pronamespace where s.nspname = 'public' and p.proname = '_eva_reauth_ok' loop execute 'drop function ' || f || ' cascade'; end loop; end $$;
do $$ declare f regprocedure; begin for f in select p.oid::regprocedure from pg_proc p join pg_namespace s on s.oid = p.pronamespace where s.nspname = 'public' and p.proname = '_eva_require_reauth' loop execute 'drop function ' || f || ' cascade'; end loop; end $$;
do $$ declare f regprocedure; begin for f in select p.oid::regprocedure from pg_proc p join pg_namespace s on s.oid = p.pronamespace where s.nspname = 'public' and p.proname = 'eva_proposal_get' loop execute 'drop function ' || f || ' cascade'; end loop; end $$;
do $$ declare f regprocedure; begin for f in select p.oid::regprocedure from pg_proc p join pg_namespace s on s.oid = p.pronamespace where s.nspname = 'public' and p.proname = 'eva_siri_propose' loop execute 'drop function ' || f || ' cascade'; end loop; end $$;
do $$ declare f regprocedure; begin for f in select p.oid::regprocedure from pg_proc p join pg_namespace s on s.oid = p.pronamespace where s.nspname = 'public' and p.proname = '_admin_confirm_vat_regime_core' loop execute 'drop function ' || f || ' cascade'; end loop; end $$;
do $$ declare f regprocedure; begin for f in select p.oid::regprocedure from pg_proc p join pg_namespace s on s.oid = p.pronamespace where s.nspname = 'public' and p.proname = '_admin_set_work_hours_core' loop execute 'drop function ' || f || ' cascade'; end loop; end $$;
do $$ declare f regprocedure; begin for f in select p.oid::regprocedure from pg_proc p join pg_namespace s on s.oid = p.pronamespace where s.nspname = 'public' and p.proname = '_eva_confirm_proposal_core' loop execute 'drop function ' || f || ' cascade'; end loop; end $$;
do $$ declare f regprocedure; begin for f in select p.oid::regprocedure from pg_proc p join pg_namespace s on s.oid = p.pronamespace where s.nspname = 'public' and p.proname = '_eva_device_create_core' loop execute 'drop function ' || f || ' cascade'; end loop; end $$;
do $$ declare f regprocedure; begin for f in select p.oid::regprocedure from pg_proc p join pg_namespace s on s.oid = p.pronamespace where s.nspname = 'public' and p.proname = '_eva_siri_set_core' loop execute 'drop function ' || f || ' cascade'; end loop; end $$;

-- 2) Déclencheur et colonnes ajoutés
drop trigger if exists trg_company_vat_confirmation on public.company_settings;
alter table public.company_settings drop column if exists vat_regime_confirmed_at, drop column if exists vat_regime_confirmed_by;
alter table public.booking_settings drop constraint if exists booking_settings_work_hours_valid, drop constraint if exists booking_settings_travel_margin_range;
alter table public.booking_settings drop column if exists work_hours, drop column if exists travel_margin_minutes;

-- 3) Tables d'EVA
drop table if exists public.eva_devices, public.eva_proposals, public.eva_journal, public.eva_tools, public.eva_dev_requests, public.eva_settings cascade;

-- 4) Les 4 fonctions existantes, définitions de PRODUCTION d'origine
CREATE OR REPLACE FUNCTION public.booking_free_slots(p_booking_id uuid, p_date date)
 RETURNS SETOF time without time zone
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  b public.bookings;
  v_dur integer;
  v_step integer;
  v_dow integer := extract(isodow from p_date);
  v_ranges int4range[];
  r int4range;
  t integer;
  v_open date;
  v_mb integer;
  v_ma integer;
  v_now_paris timestamp := now() at time zone 'Europe/Paris';
begin
  select * into b from public.bookings where id = p_booking_id;
  if not found or p_date is null then return; end if;
  select opening_date into v_open from public.booking_settings limit 1;
  if p_date < greatest(coalesce(v_open, p_date), v_now_paris::date) then return; end if;
  select coalesce(margin_before_minutes, 0), coalesce(margin_after_minutes, 0) into v_mb, v_ma from public.travel_settings limit 1;
  v_dur := coalesce(b.service_duration_minutes, 60);
  v_step := v_dur + 15;
  if v_dow = 7 then return;
  elsif v_dow = 6 then v_ranges := array[int4range(480, 720)];
  else v_ranges := array[int4range(480, 780), int4range(840, 1080)];
  end if;
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
end;
$function$
;

CREATE OR REPLACE FUNCTION public.company_billing_ready()
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
    from company_settings where id = 1), false);
$function$
;

CREATE OR REPLACE FUNCTION public.get_public_booking_settings()
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select jsonb_build_object('opening_date', opening_date, 'booking_horizon_days', booking_horizon_days)
    from booking_settings where id = 1
$function$
;

CREATE OR REPLACE FUNCTION public.is_slot_within_business_hours(p_date date, p_start_time time without time zone, p_duration_minutes integer)
 RETURNS boolean
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO 'public'
AS $function$
  select case extract(dow from p_date)::int
    when 0 then false
    when 6 then p_start_time >= time '08:00' and (p_start_time + (p_duration_minutes * interval '1 minute')) <= time '12:00'
    else (
      (p_start_time >= time '08:00' and (p_start_time + (p_duration_minutes * interval '1 minute')) <= time '13:00')
      or (p_start_time >= time '14:00' and (p_start_time + (p_duration_minutes * interval '1 minute')) <= time '18:00')
    )
  end;
$function$
;

-- Droits d'origine (relevés en production)
revoke all on function public.is_slot_within_business_hours(date, time without time zone, integer) from public, anon, authenticated, service_role;
grant execute on function public.is_slot_within_business_hours(date, time without time zone, integer) to public, anon, authenticated, service_role;
revoke all on function public.booking_free_slots(uuid, date) from public, anon, authenticated, service_role;
grant execute on function public.booking_free_slots(uuid, date) to service_role;
revoke all on function public.company_billing_ready() from public, anon, authenticated, service_role;
grant execute on function public.company_billing_ready() to authenticated, service_role;
revoke all on function public.get_public_booking_settings() from public, anon, authenticated, service_role;
grant execute on function public.get_public_booking_settings() to anon, authenticated, service_role;

commit;
