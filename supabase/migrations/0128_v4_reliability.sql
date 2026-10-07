-- 0128 — V4 : rappel client J-1, surveillance des erreurs, santé du système,
-- index des clés étrangères les plus utilisées.

-- 1) Type d'e-mail « reminder » (rappel la veille du rendez-vous).
alter table public.booking_emails drop constraint if exists booking_emails_email_type_check;
alter table public.booking_emails add constraint booking_emails_email_type_check
  check (email_type in ('received', 'confirmed', 'cancelled', 'refused', 'rescheduled',
                        'admin_new', 'admin_cancelled', 'admin_rescheduled', 'reminder'));

-- 2) Rappel quotidien (15:05 UTC = 16:05 l'hiver / 17:05 l'été à Paris).
do $$
begin
  if not exists (select 1 from cron.job where jobname = 'hayeva-appointment-reminders') then
    perform cron.schedule('hayeva-appointment-reminders', '5 15 * * *', $job$
      select net.http_post(
        url := 'https://hvlzdsuyhrhaflwutwml.supabase.co/functions/v1/process-appointment-reminders',
        headers := jsonb_build_object(
          'Content-Type', 'application/json',
          'x-cron-secret', (select decrypted_secret from vault.decrypted_secrets where name = 'hayeva_cron_shared_secret')
        ),
        body := '{}'::jsonb
      );
    $job$);
  end if;
end $$;

-- 3) Journal des erreurs critiques du navigateur — anonymisé.
--    Jamais d'identifiant de compte, d'IP, ni de contenu saisi : message
--    tronqué, adresses e-mail et suites de chiffres masquées côté serveur.
create table if not exists public.client_error_log (
  id bigint generated always as identity primary key,
  created_at timestamptz not null default now(),
  app text not null check (app in ('site', 'pro')),
  kind text not null check (kind in ('error', 'rejection')),
  message text not null,
  source text,
  page text
);
alter table public.client_error_log enable row level security;
create index if not exists client_error_log_created_idx on public.client_error_log (created_at);

create or replace function public.log_client_error(p_app text, p_kind text, p_message text, p_source text default null, p_page text default null)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_msg text;
begin
  if p_app not in ('site', 'pro') or p_kind not in ('error', 'rejection') then return; end if;
  -- Plafond global anti-abus : 300 entrées par heure au maximum.
  if (select count(*) from client_error_log where created_at > now() - interval '1 hour') >= 300 then return; end if;
  v_msg := left(coalesce(p_message, ''), 300);
  v_msg := regexp_replace(v_msg, '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}', '[email]', 'g');
  v_msg := regexp_replace(v_msg, '[0-9]{4,}', '[n]', 'g');
  if v_msg = '' then return; end if;
  insert into client_error_log (app, kind, message, source, page)
  values (p_app, p_kind, v_msg,
          left(regexp_replace(coalesce(p_source, ''), '[?#].*$', ''), 200),
          left(regexp_replace(coalesce(p_page, ''), '[0-9a-f]{8}-[0-9a-f-]{27,}', '[id]', 'gi'), 80));
end;
$$;
revoke all on function public.log_client_error(text, text, text, text, text) from public;
grant execute on function public.log_client_error(text, text, text, text, text) to anon, authenticated;

-- 4) Santé du système (Administration → Tableau de bord).
create or replace function public.admin_system_health()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_conn record;
  v_result jsonb;
begin
  if not is_admin() then
    raise exception 'Réservé à l''administration.';
  end if;
  select connected, last_pull_sync_at, last_push_sync_at, last_sync_error into v_conn
    from calendar_connections order by created_at desc limit 1;

  select jsonb_build_object(
    'checked_at', now(),
    -- Adresses de test (example.com) exclues : elles échouent par construction.
    'emails_failed_7d', (select count(*) from booking_emails where status = 'failed' and created_at > now() - interval '7 days'
                           and coalesce(recipient_email, '') not ilike '%@example.com'),
    'documents_failed_7d', (select count(*) from document_emails where status = 'failed' and created_at > now() - interval '7 days'
                              and coalesce(recipient_email, '') not ilike '%@example.com'),
    'last_email_error', (select left(error_message, 160) from booking_emails where status = 'failed'
                           and created_at > now() - interval '7 days'
                           and coalesce(recipient_email, '') not ilike '%@example.com' order by created_at desc limit 1),
    'calendar_connected', coalesce(v_conn.connected, false),
    'calendar_last_pull', v_conn.last_pull_sync_at,
    'calendar_last_push', v_conn.last_push_sync_at,
    'calendar_error', v_conn.last_sync_error,
    'calendar_bookings_in_error', (select count(*) from bookings where calendar_sync_status = 'ERROR' and date >= current_date),
    'cron_failed_24h', (select count(*) from cron.job_run_details where status = 'failed' and start_time > now() - interval '24 hours'),
    'client_errors_24h', (select count(*) from client_error_log where created_at > now() - interval '24 hours'),
    'client_errors_top', (select coalesce(jsonb_agg(jsonb_build_object('message', message, 'app', app, 'count', c) order by c desc), '[]'::jsonb)
                            from (select message, app, count(*) c from client_error_log
                                  where created_at > now() - interval '7 days' group by 1, 2 order by 3 desc limit 5) t),
    'billing_ready', company_billing_ready()
  ) into v_result;
  return v_result;
end;
$$;
revoke all on function public.admin_system_health() from public, anon;
grant execute on function public.admin_system_health() to authenticated;

-- 5) Index des clés étrangères consultées au quotidien (planning, factures,
--    calendrier, notifications) — aucun changement de comportement.
create index if not exists bookings_customer_address_id_idx on public.bookings (customer_address_id);
create index if not exists bookings_equipment_id_idx on public.bookings (equipment_id);
create index if not exists bookings_service_pack_id_idx on public.bookings (service_pack_id);
create index if not exists invoices_booking_id_idx on public.invoices (booking_id);
create index if not exists invoices_quote_id_idx on public.invoices (quote_id);
create index if not exists quotes_booking_id_idx on public.quotes (booking_id);
create index if not exists calendar_sync_log_booking_id_idx on public.calendar_sync_log (booking_id);
create index if not exists admin_notifications_booking_id_idx on public.admin_notifications (booking_id);
create index if not exists booking_move_tokens_booking_id_idx on public.booking_move_tokens (booking_id);
create index if not exists intervention_photos_item_id_idx on public.intervention_photos (intervention_item_id);
create index if not exists wallet_transactions_booking_id_idx on public.wallet_transactions (booking_id);
create index if not exists referrals_qualifying_booking_id_idx on public.referrals (qualifying_booking_id);
