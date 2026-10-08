-- Réservation : configuration centrale (date d'ouverture + horizon).
-- Avant : 2027-01-02 codé en dur dans enforce_hayeva_opening_date() ET dans
-- le site, horizon de réservation codé en dur au 31/03/2027 (plus aucun
-- créneau proposé après). Désormais une seule ligne booking_settings, lue par
-- le déclencheur serveur et par le site (get_public_booking_settings).
create table if not exists public.booking_settings (
  id integer primary key default 1 check (id = 1),
  opening_date date not null default date '2027-01-02',
  booking_horizon_days integer not null default 90 check (booking_horizon_days between 7 and 365),
  updated_at timestamptz not null default now(),
  updated_by uuid
);
insert into public.booking_settings (id) values (1) on conflict (id) do nothing;
alter table public.booking_settings enable row level security;
create policy "booking_settings: admin all" on public.booking_settings for all to authenticated using (public.is_admin()) with check (public.is_admin());

create or replace function public.get_public_booking_settings()
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object('opening_date', opening_date, 'booking_horizon_days', booking_horizon_days)
    from booking_settings where id = 1
$$;
revoke all on function public.get_public_booking_settings() from public;
grant execute on function public.get_public_booking_settings() to anon, authenticated;

create or replace function public.enforce_hayeva_opening_date()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare v_open date := coalesce((select opening_date from booking_settings where id = 1), date '2027-01-02');
begin
  if NEW.date < v_open and not (is_admin() or auth.role() = 'service_role') then
    raise exception 'HAYEVA planifie ses interventions à partir du % — aucun rendez-vous avant cette date.', to_char(v_open, 'DD/MM/YYYY');
  end if;
  return NEW;
end;
$$;
