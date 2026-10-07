-- V2 phase 17 — Demande d'avis Google après intervention.
--
-- • company_settings.google_review_url : lien « laisser un avis » de la
--   fiche Google de l'entreprise, saisi par l'admin. Vide = fonctionnalité
--   inactive (aucun e-mail).
-- • Un rendez-vous terminé (COMPLETED) il y a 1 à 3 jours donne lieu à UNE
--   demande (unique booking_id) ; au plus une demande envoyée par adresse
--   e-mail sur 12 mois (contrôlé par l'Edge Function process-review-requests).

alter table public.company_settings add column if not exists google_review_url text
  check (google_review_url is null or google_review_url ~* '^https://');

create table if not exists public.review_requests (
  id uuid primary key default gen_random_uuid(),
  booking_id uuid not null unique references public.bookings(id) on delete cascade,
  status text not null default 'pending' check (status in ('pending', 'sent', 'failed', 'skipped')),
  recipient_email text,
  error_message text,
  sent_at timestamptz,
  created_at timestamptz not null default now()
);
alter table public.review_requests enable row level security;
create policy "review_requests: admin read" on public.review_requests for select to authenticated using (public.is_admin());

create or replace function public.claim_due_review_requests()
returns table (request_id uuid, booking_id uuid)
language sql
security definer
set search_path = public
as $$
  insert into review_requests (booking_id)
  select b.id from bookings b
   where nullif(trim((select google_review_url from company_settings where id = 1)), '') is not null
     and b.status = 'COMPLETED'
     and b.date between ((now() at time zone 'Europe/Paris')::date - 3) and ((now() at time zone 'Europe/Paris')::date - 1)
  on conflict on constraint review_requests_booking_id_key do nothing
  returning id, review_requests.booking_id;
$$;
revoke all on function public.claim_due_review_requests() from public, anon, authenticated;
grant execute on function public.claim_due_review_requests() to service_role;

select cron.schedule(
  'hayeva-review-requests',
  '27 8 * * *',
  $$
  select net.http_post(
    url := 'https://hvlzdsuyhrhaflwutwml.supabase.co/functions/v1/process-review-requests',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'x-cron-secret', (select decrypted_secret from vault.decrypted_secrets where name = 'hayeva_cron_shared_secret')
    ),
    body := '{}'::jsonb
  );
  $$
);
