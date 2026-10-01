-- ============================================================
-- Dossier client 360° HAYEVA — une seule fiche client centrale, qu'il
-- s'agisse d'un compte enregistré (customer_user_id) OU d'un client
-- invité (guest_name/guest_email/guest_phone, jusqu'ici sans AUCUNE fiche
-- persistante : ni équipement, ni contrat, ni devis ne pouvaient lui être
-- rattachés). Non destructif : aucune colonne existante supprimée, tout
-- est ADDITIF + rétro-rempli prudemment (jamais une fusion de personnes
-- devinée sur le seul nom).
-- ============================================================

-- ------------------------------------------------------------
-- 1. Table clients : identité centrale, couvre invités et comptes.
-- ------------------------------------------------------------
create table if not exists clients (
  id uuid primary key default gen_random_uuid(),
  user_id uuid references auth.users(id) on delete set null,
  first_name text,
  last_name text,
  email text,
  phone text,
  address text,
  postal_code text,
  city text,
  client_type text not null default 'particulier' check (client_type in ('particulier', 'professionnel')),
  notes text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  -- Fusion manuelle (section 6) : un client fusionné pointe vers le
  -- survivant plutôt que d'être supprimé — historique jamais perdu.
  merged_into uuid references clients(id) on delete set null
);

alter table clients enable row level security;
create policy "clients: admin full access" on clients
  for all using (is_admin()) with check (is_admin());
create policy "clients: self read" on clients
  for select using (user_id = auth.uid());

create unique index if not exists idx_clients_user_id on clients(user_id) where user_id is not null;
create index if not exists idx_clients_email on clients(lower(email)) where email is not null;
create index if not exists idx_clients_phone on clients(phone) where phone is not null;
create index if not exists idx_clients_merged_into on clients(merged_into) where merged_into is not null;
create index if not exists idx_clients_name_trgm on clients using gin ((coalesce(first_name,'') || ' ' || coalesce(last_name,'')) gin_trgm_ops);

-- set_updated_at() peut ne pas exister selon les migrations déjà posées —
-- créée ici de façon idempotente si besoin (ne redéfinit rien d'existant).
do $$ begin
  if not exists (select 1 from pg_proc where proname = 'set_updated_at') then
    create function set_updated_at() returns trigger language plpgsql as $f$
    begin new.updated_at = now(); return new; end; $f$;
  end if;
end $$;

create trigger trg_clients_updated_at
  before update on clients for each row execute function set_updated_at();

-- ------------------------------------------------------------
-- 2. Rattachement client_id partout où un client peut être concerné —
--    AJOUTÉ, jamais en remplacement de customer_user_id (toujours lu par
--    le code existant, qui continue de fonctionner à l'identique).
-- ------------------------------------------------------------
alter table bookings add column if not exists client_id uuid references clients(id) on delete set null;
alter table customer_equipment add column if not exists client_id uuid references clients(id) on delete set null;
alter table service_contracts add column if not exists client_id uuid references clients(id) on delete set null;
alter table quotes add column if not exists client_id uuid references clients(id) on delete set null;
alter table invoices add column if not exists client_id uuid references clients(id) on delete set null;

create index if not exists idx_bookings_client_id on bookings(client_id);
create index if not exists idx_customer_equipment_client_id on customer_equipment(client_id);
create index if not exists idx_service_contracts_client_id on service_contracts(client_id);
create index if not exists idx_quotes_client_id on quotes(client_id);
create index if not exists idx_invoices_client_id on invoices(client_id);

-- ------------------------------------------------------------
-- 3. Équipements : champs métier détaillés (section 3), tous facultatifs.
-- ------------------------------------------------------------
alter table customer_equipment
  add column if not exists reference text,
  add column if not exists serial_number text,
  add column if not exists power_capacity text,
  add column if not exists approx_year integer,
  add column if not exists location text,
  add column if not exists photos jsonb not null default '[]'::jsonb;

-- ------------------------------------------------------------
-- 4. Déduplication automatique (section 6) : trouve un client existant
--    par user_id (compte) sinon par email/téléphone EXACT (jamais par nom
--    seul, qui resterait trop fragile — deux "Martin" ne sont pas la même
--    personne). Crée un nouveau client si rien de fiable ne correspond.
--    SECURITY DEFINER pour pouvoir lire/écrire clients quel que soit
--    l'appelant (le trigger s'exécute au nom de qui crée le booking —
--    client authentifié, invité via la fonction anonyme existante, ou
--    admin).
-- ------------------------------------------------------------
create or replace function find_or_create_client(
  p_user_id uuid, p_email text, p_phone text,
  p_first_name text, p_last_name text, p_address text
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_client_id uuid;
  v_email text := nullif(trim(lower(p_email)), '');
  v_phone text := nullif(regexp_replace(coalesce(p_phone, ''), '[^0-9+]', '', 'g'), '');
begin
  if p_user_id is not null then
    select id into v_client_id from clients where user_id = p_user_id and merged_into is null limit 1;
    if v_client_id is not null then return v_client_id; end if;
  end if;

  if v_email is not null then
    select id into v_client_id from clients where lower(email) = v_email and merged_into is null order by created_at limit 1;
    if v_client_id is not null then
      -- Un compte vient de se créer pour un client déjà connu comme
      -- invité (même e-mail) : rattache le compte à sa fiche existante au
      -- lieu d'en garder deux séparées.
      if p_user_id is not null then update clients set user_id = p_user_id where id = v_client_id and user_id is null; end if;
      return v_client_id;
    end if;
  end if;

  if v_phone is not null then
    select id into v_client_id from clients
      where regexp_replace(coalesce(phone, ''), '[^0-9+]', '', 'g') = v_phone and merged_into is null
      order by created_at limit 1;
    if v_client_id is not null then
      if p_user_id is not null then update clients set user_id = p_user_id where id = v_client_id and user_id is null; end if;
      return v_client_id;
    end if;
  end if;

  insert into clients (user_id, first_name, last_name, email, phone, address)
  values (p_user_id, p_first_name, p_last_name, p_email, p_phone, p_address)
  returning id into v_client_id;
  return v_client_id;
end;
$$;

revoke all on function find_or_create_client(uuid, text, text, text, text, text) from public;
grant execute on function find_or_create_client(uuid, text, text, text, text, text) to authenticated, anon;

-- ------------------------------------------------------------
-- 5. Trigger : chaque réservation (créée par n'importe quel parcours —
--    client connecté, invité, admin) se rattache automatiquement à un
--    client, sans toucher au code frontend existant qui insère déjà dans
--    bookings.
-- ------------------------------------------------------------
create or replace function bookings_attach_client()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_first text; v_last text;
begin
  if new.client_id is not null then return new; end if;
  if new.guest_name is not null then
    v_first := split_part(new.guest_name, ' ', 1);
    v_last := nullif(trim(substring(new.guest_name from length(v_first) + 1)), '');
  end if;
  new.client_id := find_or_create_client(
    new.customer_user_id, new.guest_email, new.guest_phone,
    v_first, v_last, new.guest_address
  );
  return new;
end;
$$;

drop trigger if exists trg_bookings_attach_client on bookings;
create trigger trg_bookings_attach_client
  before insert on bookings
  for each row execute function bookings_attach_client();

comment on function bookings_attach_client is 'Rattache automatiquement chaque nouvelle réservation à un client existant (par compte, puis e-mail, puis téléphone) ou en crée un nouveau — jamais par simple correspondance de nom (section 6, cahier des charges du 03/10/2026).';

-- ------------------------------------------------------------
-- 6. Rétro-remplissage PRUDENT des données existantes : un client par
--    customer_user_id distinct (comptes), un client par (guest_email ou
--    guest_phone) distinct pour les invités — jamais par nom seul. Les
--    bookings restent reliés à leur client via client_id une fois celui-ci
--    créé. Aucune donnée existante modifiée ou supprimée.
-- ------------------------------------------------------------
insert into clients (user_id, first_name, last_name, email, phone)
select distinct on (b.customer_user_id)
  b.customer_user_id, cp.first_name, cp.last_name, prof.email, cp.phone
from bookings b
left join customer_profiles cp on cp.user_id = b.customer_user_id
left join profiles prof on prof.user_id = b.customer_user_id
where b.customer_user_id is not null
  and not exists (select 1 from clients c where c.user_id = b.customer_user_id)
order by b.customer_user_id, b.created_at;

with guest_identities as (
  select distinct on (coalesce(lower(guest_email), '~' || guest_phone))
    guest_name, guest_email, guest_phone, guest_address, created_at
  from bookings
  where customer_user_id is null and (guest_email is not null or guest_phone is not null)
  order by coalesce(lower(guest_email), '~' || guest_phone), created_at
)
insert into clients (first_name, last_name, email, phone, address)
select
  split_part(guest_name, ' ', 1),
  nullif(trim(substring(guest_name from length(split_part(guest_name, ' ', 1)) + 1)), ''),
  guest_email, guest_phone, guest_address
from guest_identities gi
where not exists (
  select 1 from clients c
  where (gi.guest_email is not null and lower(c.email) = lower(gi.guest_email))
     or (gi.guest_phone is not null and regexp_replace(coalesce(c.phone,''), '[^0-9+]', '', 'g') = regexp_replace(gi.guest_phone, '[^0-9+]', '', 'g'))
);

-- Rattache chaque booking existant à son client (déjà créé ci-dessus),
-- même logique de correspondance que le trigger, en lecture seule ici
-- (ne recrée jamais de client en double).
update bookings b set client_id = c.id
from clients c
where b.client_id is null and b.customer_user_id is not null and c.user_id = b.customer_user_id;

update bookings b set client_id = c.id
from clients c
where b.client_id is null and b.customer_user_id is null and b.guest_email is not null
  and lower(c.email) = lower(b.guest_email);

update bookings b set client_id = c.id
from clients c
where b.client_id is null and b.customer_user_id is null and b.guest_email is null and b.guest_phone is not null
  and regexp_replace(coalesce(c.phone,''), '[^0-9+]', '', 'g') = regexp_replace(b.guest_phone, '[^0-9+]', '', 'g');

-- Équipements/contrats/devis/factures existants : rattachés via le
-- customer_user_id qu'ils portent déjà (comptes uniquement — les
-- invités n'ont jamais pu avoir d'équipement enregistré avant cette
-- migration, donc rien à deviner ici).
update customer_equipment e set client_id = c.id from clients c where e.client_id is null and c.user_id = e.customer_user_id;
update service_contracts s set client_id = c.id from clients c where s.client_id is null and c.user_id = s.customer_user_id;
update quotes q set client_id = c.id from clients c where q.client_id is null and c.user_id = q.customer_user_id;
update invoices i set client_id = c.id from clients c where i.client_id is null and c.user_id = i.customer_user_id;

-- ------------------------------------------------------------
-- 7. Fusion manuelle de doublons (section 6), avec aperçu avant
--    validation côté admin (la fonction fait le travail, l'aperçu est
--    construit côté frontend avant l'appel). Réattribue tout ce qui
--    pointe vers le doublon vers le survivant, puis marque le doublon
--    fusionné (jamais supprimé : historique conservé).
-- ------------------------------------------------------------
create or replace function admin_merge_clients(p_keep_id uuid, p_merge_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not is_admin() then
    raise exception 'Accès réservé à l''administration.';
  end if;
  if p_keep_id = p_merge_id then
    raise exception 'Impossible de fusionner un client avec lui-même.';
  end if;

  update bookings set client_id = p_keep_id where client_id = p_merge_id;
  update customer_equipment set client_id = p_keep_id where client_id = p_merge_id;
  update service_contracts set client_id = p_keep_id where client_id = p_merge_id;
  update quotes set client_id = p_keep_id where client_id = p_merge_id;
  update invoices set client_id = p_keep_id where client_id = p_merge_id;

  update clients set merged_into = p_keep_id where id = p_merge_id;
end;
$$;

revoke all on function admin_merge_clients(uuid, uuid) from public;
grant execute on function admin_merge_clients(uuid, uuid) to authenticated;

-- ------------------------------------------------------------
-- 8. Détection de doublons probables (pour l'outil de fusion admin) :
--    deux clients distincts partageant le même e-mail ou téléphone normalisé
--    (ne devrait plus arriver pour les nouvelles données grâce au trigger,
--    mais peut exister dans l'historique rétro-rempli si deux comptes
--    différents utilisaient la même adresse e-mail à des moments différents).
-- ------------------------------------------------------------
create or replace function admin_find_duplicate_clients()
returns table (shared_value text, client_ids uuid[])
language plpgsql
security definer
set search_path = public
as $$
begin
  if not is_admin() then
    raise exception 'Accès réservé à l''administration.';
  end if;
  return query
  select lower(email), array_agg(id order by created_at)
  from clients where email is not null and merged_into is null
  group by lower(email) having count(*) > 1
  union all
  select regexp_replace(phone, '[^0-9+]', '', 'g'), array_agg(id order by created_at)
  from clients where phone is not null and merged_into is null
  group by regexp_replace(phone, '[^0-9+]', '', 'g') having count(*) > 1;
end;
$$;

revoke all on function admin_find_duplicate_clients() from public;
grant execute on function admin_find_duplicate_clients() to authenticated;
