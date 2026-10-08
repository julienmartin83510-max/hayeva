-- CRM professionnel léger, sous-traitance, véhicule et outillage.
-- Volontairement simple (entreprise exploitée par une personne) ; tout est
-- réservé à l'admin (RLS is_admin()).

create table if not exists public.partners (
  id uuid primary key default gen_random_uuid(),
  company text not null check (length(trim(company)) between 1 and 200),
  contact_name text,
  phone text,
  email text,
  city text,
  category text not null default 'autre' check (category in ('syndic','camping','hotel','agence_immobiliere','conciergerie','plombier','chauffagiste','entreprise_generale','sous_traitant','fournisseur','assurance','autre')),
  status text not null default 'A_CONTACTER' check (status in ('A_CONTACTER','CONTACTE','A_RELANCER','INTERESSE','PARTENAIRE','REFUSE')),
  notes text,
  last_contact_at date,
  next_followup_at date,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists partners_followup_idx on public.partners(next_followup_at);

create table if not exists public.subcontracts (
  id uuid primary key default gen_random_uuid(),
  partner_id uuid not null references public.partners(id) on delete restrict,
  booking_id uuid references public.bookings(id) on delete set null,
  description text not null check (length(trim(description)) between 1 and 500),
  status text not null default 'PROPOSE' check (status in ('PROPOSE','ACCEPTE','EN_COURS','TERMINE','ANNULE')),
  agreed_amount_cents integer check (agreed_amount_cents is null or agreed_amount_cents >= 0),
  notes text,
  history jsonb not null default '[]'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- Historique automatique des changements de statut / montant.
create or replace function public.subcontracts_history()
returns trigger
language plpgsql
as $$
begin
  if tg_op = 'UPDATE' and (new.status is distinct from old.status or new.agreed_amount_cents is distinct from old.agreed_amount_cents) then
    new.history := coalesce(old.history, '[]'::jsonb) || jsonb_build_object('at', now(), 'status', new.status, 'amount_cents', new.agreed_amount_cents);
  elsif tg_op = 'INSERT' then
    new.history := jsonb_build_array(jsonb_build_object('at', now(), 'status', new.status, 'amount_cents', new.agreed_amount_cents));
  end if;
  new.updated_at := now();
  return new;
end;
$$;
create trigger trg_subcontracts_history before insert or update on public.subcontracts
  for each row execute function public.subcontracts_history();

create table if not exists public.vehicles (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  plate text,
  mileage_km integer check (mileage_km is null or mileage_km >= 0),
  next_service_date date,
  next_service_km integer,
  notes text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create table if not exists public.vehicle_expenses (
  id uuid primary key default gen_random_uuid(),
  vehicle_id uuid not null references public.vehicles(id) on delete cascade,
  spent_on date not null default ((now() at time zone 'Europe/Paris')::date),
  kind text not null default 'autre' check (kind in ('carburant','entretien','reparation','pneus','assurance','controle_technique','peage_parking','autre')),
  amount_cents integer not null check (amount_cents >= 0),
  mileage_km integer,
  note text,
  created_at timestamptz not null default now()
);
create table if not exists public.tools (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  brand text,
  reference text,
  purchase_date date,
  condition text not null default 'BON' check (condition in ('BON','A_SURVEILLER','HS')),
  warranty_until date,
  notes text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

do $$ declare t text; begin
  foreach t in array array['partners','subcontracts','vehicles','vehicle_expenses','tools'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('create policy "%s: admin only" on public.%I for all to authenticated using (public.is_admin()) with check (public.is_admin())', t, t);
    execute format('revoke all on public.%I from anon', t);
  end loop;
end $$;
