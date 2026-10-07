-- V2 phase 3 — Rappels d'entretien des équipements (J-30, J-7, échéance).
--
-- • Échéance = dernier entretien (ou, à défaut, date d'installation)
--   + périodicité (customer_equipment.maintenance_interval_months, sinon
--   12 mois pour climatisation, chaudières gaz / fioul et pompe à chaleur ;
--   aucun rappel automatique pour les autres catégories).
-- • Équipement couvert par un contrat d'entretien actif : ignoré (le
--   contrat a déjà ses propres rappels, generate_reminder_jobs).
-- • Anti-doublon : unique (equipment_id, due_date, step). Fenêtres de
--   7 jours par étape : jamais de rattrapage en rafale.
-- • Un rapport d'intervention finalisé sur l'équipement met à jour
--   last_service_at (donc l'échéance suivante) automatiquement.
-- • Envoi : Edge Function process-maintenance-reminders (cron quotidien).

alter table public.customer_equipment
  add column if not exists maintenance_reminders_enabled boolean not null default true,
  add column if not exists maintenance_interval_months integer check (maintenance_interval_months between 1 and 120);

create table if not exists public.maintenance_reminders (
  id uuid primary key default gen_random_uuid(),
  equipment_id uuid not null references public.customer_equipment(id) on delete cascade,
  due_date date not null,
  step text not null check (step in ('J-30', 'J-7', 'J0')),
  status text not null default 'pending' check (status in ('pending', 'sent', 'failed', 'skipped')),
  recipient_email text,
  error_message text,
  sent_at timestamptz,
  created_at timestamptz not null default now(),
  unique (equipment_id, due_date, step)
);
create index if not exists maintenance_reminders_equipment_idx on public.maintenance_reminders(equipment_id);
alter table public.maintenance_reminders enable row level security;
create policy "maintenance_reminders: admin read" on public.maintenance_reminders for select to authenticated using (public.is_admin());

create or replace function public.equipment_next_maintenance_due(e public.customer_equipment)
returns date
language sql
stable
set search_path = public
as $$
  select (coalesce(e.last_service_at, e.installed_at)
          + make_interval(months => coalesce(e.maintenance_interval_months,
              case when e.equipment_type in ('climatisation', 'chaudiere_gaz', 'chaudiere_fioul', 'pac') then 12 end)))::date
$$;

create or replace function public.claim_due_maintenance_reminders()
returns table (reminder_id uuid, equipment_id uuid, due_date date, step text)
language sql
security definer
set search_path = public
as $$
  with today as (select (now() at time zone 'Europe/Paris')::date as d),
  eq as (
    select e.id, public.equipment_next_maintenance_due(e) as due
      from customer_equipment e
     where e.maintenance_reminders_enabled
       and not exists (select 1 from service_contracts sc where sc.equipment_id = e.id and sc.status = 'active')
  ),
  due as (
    select eq.id, eq.due,
           case when t.d between eq.due - 30 and eq.due - 24 then 'J-30'
                when t.d between eq.due - 7 and eq.due - 1 then 'J-7'
                when t.d between eq.due and eq.due + 6 then 'J0' end as step
      from eq, today t
     where eq.due is not null
  )
  insert into maintenance_reminders (equipment_id, due_date, step)
  select id, due, step from due where step is not null
  on conflict on constraint maintenance_reminders_equipment_id_due_date_step_key do nothing
  returning id, maintenance_reminders.equipment_id, maintenance_reminders.due_date, maintenance_reminders.step;
$$;
revoke all on function public.claim_due_maintenance_reminders() from public, anon, authenticated;
grant execute on function public.claim_due_maintenance_reminders() to service_role;

-- Rapport d'intervention finalisé → date du dernier entretien de l'équipement.
create or replace function public.intervention_update_equipment_service()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.equipment_id is not null and new.report_status = 'FINALIZED'
     and (tg_op = 'INSERT' or old.report_status is distinct from 'FINALIZED') then
    update customer_equipment
       set last_service_at = greatest(coalesce(last_service_at, '1900-01-01'::date),
                                      (coalesce(new.performed_at, new.ended_at, now()) at time zone 'Europe/Paris')::date)
     where id = new.equipment_id;
  end if;
  return new;
end;
$$;
create trigger trg_intervention_equipment_service after insert or update of report_status on public.interventions
  for each row execute function public.intervention_update_equipment_service();

select cron.schedule(
  'hayeva-maintenance-reminders',
  '17 7 * * *',
  $$
  select net.http_post(
    url := 'https://hvlzdsuyhrhaflwutwml.supabase.co/functions/v1/process-maintenance-reminders',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'x-cron-secret', (select decrypted_secret from vault.decrypted_secrets where name = 'hayeva_cron_shared_secret')
    ),
    body := '{}'::jsonb
  );
  $$
);
