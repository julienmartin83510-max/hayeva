-- V2 phase 4 — Relances automatiques des devis envoyés (J+3, J+7, J+14).
--
-- • Une relance n'est envoyée que pour un devis encore 'SENT' (jamais
--   accepté, refusé ou expiré), sans nouvelle version, et dont les relances
--   n'ont pas été désactivées par l'admin (quotes.followups_enabled).
-- • Anti-doublon : contrainte unique (quote_id, step). Chaque étape a une
--   fenêtre de 4 jours (J+3..J+6, J+7..J+10, J+14..J+17) : une étape manquée
--   (ex. devis envoyé il y a 30 jours au moment du déploiement) n'est jamais
--   rattrapée en rafale.
-- • Envoi : Edge Function process-quote-followups (cron horaire, heures de
--   journée), authentifiée par le secret partagé du Vault (même mécanisme
--   que hayeva-reminder-cycle, 0053).

alter table public.quotes add column if not exists followups_enabled boolean not null default true;

create table if not exists public.quote_followups (
  id uuid primary key default gen_random_uuid(),
  quote_id uuid not null references public.quotes(id) on delete cascade,
  step integer not null check (step in (3, 7, 14)),
  status text not null default 'pending' check (status in ('pending', 'sent', 'failed', 'skipped')),
  recipient_email text,
  error_message text,
  sent_at timestamptz,
  created_at timestamptz not null default now(),
  unique (quote_id, step)
);
create index if not exists quote_followups_quote_idx on public.quote_followups(quote_id);
alter table public.quote_followups enable row level security;
create policy "quote_followups: admin read" on public.quote_followups for select to authenticated using (public.is_admin());

-- Réserve (de façon atomique et idempotente) les relances dues maintenant.
-- Appelée uniquement par l'Edge Function (service_role).
create or replace function public.claim_due_quote_followups()
returns table (followup_id uuid, quote_id uuid, step integer)
language sql
security definer
set search_path = public
as $$
  with today as (select (now() at time zone 'Europe/Paris')::date as d),
  candidates as (
    select q.id as qid,
           (select max(s) from unnest(array[3, 7, 14]) s
             where s <= (t.d - (q.sent_at at time zone 'Europe/Paris')::date)
               and (t.d - (q.sent_at at time zone 'Europe/Paris')::date) <= s + 3) as due_step
      from quotes q, today t
     where q.status = 'SENT'
       and q.followups_enabled
       and q.sent_at is not null
       and not exists (select 1 from quotes c where c.parent_quote_id = q.id)
  )
  insert into quote_followups (quote_id, step)
  select qid, due_step from candidates where due_step is not null
  on conflict on constraint quote_followups_quote_id_step_key do nothing
  returning id, quote_followups.quote_id, quote_followups.step;
$$;
revoke all on function public.claim_due_quote_followups() from public, anon, authenticated;
grant execute on function public.claim_due_quote_followups() to service_role;

-- Planification : toutes les heures de 7 h à 17 h UTC (≈ 9 h-19 h Paris).
select cron.schedule(
  'hayeva-quote-followups',
  '7 7-17 * * *',
  $$
  select net.http_post(
    url := 'https://hvlzdsuyhrhaflwutwml.supabase.co/functions/v1/process-quote-followups',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'x-cron-secret', (select decrypted_secret from vault.decrypted_secrets where name = 'hayeva_cron_shared_secret')
    ),
    body := '{}'::jsonb
  );
  $$
);

-- Seul l'admin (ou le service) peut couper / réactiver les relances.
create or replace function public.protect_quote_invoice_fields()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if not (
    is_admin()
    or auth.role() = 'service_role'
    or coalesce(current_setting('app.bypass_quote_protect', true), '') = 'on'
  ) then
    new.status := old.status;
    new.subtotal_cents := old.subtotal_cents;
    new.travel_fee_cents := old.travel_fee_cents;
    new.discount_cents := old.discount_cents;
    new.total_cents := old.total_cents;
    if tg_table_name = 'quotes' then
      new.followups_enabled := old.followups_enabled;
    end if;
  end if;
  return new;
end;
$$;
