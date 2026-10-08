-- V2 phase 59 — « Je suis en route » : e-mail au client avec l'heure
-- d'arrivée estimée, envoyé depuis la vue technicien (Edge Function
-- notify-on-the-way, admin uniquement). Une seule notification par
-- rendez-vous (unique booking_id) : jamais de doublon en cas de double clic.

create table if not exists public.booking_on_the_way (
  id uuid primary key default gen_random_uuid(),
  booking_id uuid not null unique references public.bookings(id) on delete cascade,
  eta_minutes integer not null check (eta_minutes between 5 and 180),
  status text not null default 'pending' check (status in ('pending', 'sent', 'failed', 'skipped')),
  recipient_email text,
  error_message text,
  sent_by uuid,
  sent_at timestamptz,
  created_at timestamptz not null default now()
);
alter table public.booking_on_the_way enable row level security;
create policy "booking_on_the_way: admin read" on public.booking_on_the_way for select to authenticated using (public.is_admin());
