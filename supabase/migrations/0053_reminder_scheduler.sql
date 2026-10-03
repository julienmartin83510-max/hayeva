-- ============================================================
-- Système de rappels RÉELLEMENT automatique (pg_cron + pg_net, tous deux
-- déjà disponibles sur ce projet — pg_cron installé pour l'occasion,
-- pg_net et supabase_vault l'étaient déjà). Remplace le simple
-- contract_reminder_config (0052, toujours utilisé pour les délais
-- GLOBAUX du contrat) par un système par type d'équipement, idempotent,
-- avec journalisation réelle (jamais un double envoi).
-- ============================================================

-- ------------------------------------------------------------
-- reminder_rules : délais ACTIVABLES/DÉSACTIVABLES par catégorie
-- d'équipement (section 5) — jamais codés en dur dans le frontend.
-- ------------------------------------------------------------
create table if not exists reminder_rules (
  id uuid primary key default gen_random_uuid(),
  equipment_category text not null check (equipment_category in (
    'climatisation', 'chaudiere_gaz', 'chaudiere_fioul', 'chauffage', 'contrat_serenite', 'autre'
  )),
  days_before integer not null check (days_before > 0),
  is_active boolean not null default true,
  channel text not null default 'email' check (channel in ('email', 'sms')),
  created_at timestamptz not null default now(),
  unique (equipment_category, days_before, channel)
);

alter table reminder_rules enable row level security;
create policy "reminder_rules: admin full access" on reminder_rules
  for all using (is_admin()) with check (is_admin());

insert into reminder_rules (equipment_category, days_before, channel) values
  ('contrat_serenite', 30, 'email'),
  ('contrat_serenite', 15, 'email'),
  ('contrat_serenite', 7, 'email'),
  ('climatisation', 30, 'email'),
  ('chaudiere_gaz', 30, 'email'),
  ('chaudiere_fioul', 30, 'email'),
  ('chauffage', 30, 'email')
on conflict (equipment_category, days_before, channel) do nothing;

-- ------------------------------------------------------------
-- reminder_jobs : un job par (contrat, règle) — la contrainte unique est
-- CE QUI REND LE SYSTÈME IDEMPOTENT. generate_reminder_jobs() peut être
-- rappelée autant de fois que nécessaire (toutes les 15 min via cron) :
-- un même rappel n'est jamais recréé/renvoyé deux fois.
-- ------------------------------------------------------------
create table if not exists reminder_jobs (
  id uuid primary key default gen_random_uuid(),
  customer_user_id uuid not null references auth.users(id) on delete cascade,
  contract_id uuid references service_contracts(id) on delete cascade,
  equipment_id uuid references customer_equipment(id) on delete cascade,
  reminder_rule_id uuid not null references reminder_rules(id) on delete cascade,
  reminder_type text not null,                 -- libellé figé au moment de la génération (ex. 'contrat_serenite_J-30')
  scheduled_for date not null,
  channel text not null default 'email' check (channel in ('email', 'sms')),
  status text not null default 'pending' check (status in ('pending', 'processing', 'sent', 'failed', 'cancelled')),
  sent_at timestamptz,
  result text,
  error text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (contract_id, reminder_rule_id)
);

alter table reminder_jobs enable row level security;
create policy "reminder_jobs: customer sees own" on reminder_jobs
  for select using (customer_user_id = auth.uid());
create policy "reminder_jobs: admin full access" on reminder_jobs
  for all using (is_admin()) with check (is_admin());

create index if not exists idx_reminder_jobs_status_date on reminder_jobs(status, scheduled_for);
create index if not exists idx_reminder_jobs_contract on reminder_jobs(contract_id);

-- ------------------------------------------------------------
-- Génération idempotente des rappels dus, à partir des contrats ACTIFS et
-- des règles actives correspondant à leur combustible. SECURITY DEFINER
-- pour pouvoir lire/écrire sans dépendre du rôle appelant (appelée par
-- pg_cron, qui s'exécute comme le propriétaire de la fonction).
-- ------------------------------------------------------------
create or replace function generate_reminder_jobs()
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_count integer := 0;
begin
  insert into reminder_jobs (customer_user_id, contract_id, equipment_id, reminder_rule_id, reminder_type, scheduled_for, channel)
  select
    sc.customer_user_id, sc.id, sc.equipment_id, rr.id,
    (case sc.energy_type when 'gaz' then 'chaudiere_gaz' else 'chaudiere_fioul' end) || '_J-' || rr.days_before,
    sc.end_date - rr.days_before,
    rr.channel
  from service_contracts sc
  join reminder_rules rr on rr.equipment_category = 'contrat_serenite' and rr.is_active
  where sc.status = 'active' and sc.end_date is not null
  on conflict (contract_id, reminder_rule_id) do nothing;
  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

comment on function generate_reminder_jobs is 'Idempotent : peut être rappelée indéfiniment (toutes les 15 min via pg_cron) sans jamais dupliquer un rappel déjà créé pour ce (contrat, règle) — voir la contrainte unique sur reminder_jobs.';

-- ------------------------------------------------------------
-- pg_cron : exécute generate_reminder_jobs() PUIS appelle l'Edge Function
-- process-reminders (qui envoie réellement les e-mails dus et met à jour
-- le statut) via pg_net, authentifiée par un secret partagé stocké dans
-- Supabase Vault — jamais la clé service_role exposée ici.
-- ------------------------------------------------------------
select cron.schedule(
  'hayeva-reminder-cycle',
  '*/15 * * * *',
  $$
  select generate_reminder_jobs();
  select net.http_post(
    url := 'https://hvlzdsuyhrhaflwutwml.supabase.co/functions/v1/process-reminders',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'x-cron-secret', (select decrypted_secret from vault.decrypted_secrets where name = 'hayeva_cron_shared_secret')
    ),
    body := '{}'::jsonb
  );
  $$
);
