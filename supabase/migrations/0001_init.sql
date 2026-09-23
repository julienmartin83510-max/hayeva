-- Migration initiale — Phase A (Base SQL + RLS + catalogue services)
-- Particulier + Professionnel + Admin.
-- Ne couvre pas encore : routing réel, tournées, PDF, facturation légale,
-- notifications, vérification SIRET externe.
--
-- Les identifiants techniques (rôles, tables, fonctions) sont volontairement
-- génériques et indépendants du nom commercial de l'entreprise (ex. "admin",
-- pas "admin_sud_maintenance") pour rester valables si ce nom change un jour.
--
-- NE PAS EXÉCUTER sans relecture et validation explicite.
-- À exécuter dans Supabase : SQL Editor > New query > coller ce fichier > Run.
-- Reproductible : peut être rejoué sur un projet vierge pour recréer la base à l'identique.

-- ============================================================
-- EXTENSIONS
-- ============================================================
-- pgcrypto : uniquement pour gen_random_uuid() utilisé comme clé primaire
-- par défaut sur toutes les tables. Aucune autre extension n'est nécessaire
-- pour cette phase (pas de vérification SIRET externe, pas de géo-index).
create extension if not exists "pgcrypto";

-- ============================================================
-- TABLES — COMMUNES
-- ============================================================

-- Rôle global de chaque utilisateur. Déterminé et modifié UNIQUEMENT côté
-- serveur/admin (voir policies plus bas) : jamais par l'utilisateur lui-même.
-- Ne pas confondre avec professional_members.role, qui représente le rôle
-- DANS une entreprise (owner/member), pas le type de compte global.
create table profiles (
  user_id uuid primary key references auth.users(id) on delete cascade,
  email text not null,
  global_role text not null default 'customer'
    check (global_role in ('customer','professional','admin')),
  created_at timestamptz not null default now()
);

-- ============================================================
-- TABLES — PARTICULIER
-- ============================================================

create table customer_profiles (
  user_id uuid primary key references auth.users(id) on delete cascade,
  first_name text,
  last_name text,
  phone text,
  created_at timestamptz not null default now()
);

create table customer_addresses (
  id uuid primary key default gen_random_uuid(),
  customer_user_id uuid not null references auth.users(id) on delete cascade,
  label text not null,                 -- "Maison principale", "Appartement secondaire"...
  address text not null,
  postal_code text,
  city text,
  is_default boolean not null default false,
  created_at timestamptz not null default now()
);

create table customer_equipment (
  id uuid primary key default gen_random_uuid(),
  customer_user_id uuid not null references auth.users(id) on delete cascade,
  address_id uuid references customer_addresses(id) on delete set null,
  equipment_type text not null check (equipment_type in (
    'climatisation','chaudiere_gaz','chaudiere_fioul','chauffe_eau','pac','autre'
  )),
  brand text,
  model text,
  installed_at date,
  notes text,
  last_service_at date,                -- mis à jour manuellement/depuis interventions ; aucune règle de rappel en V1
  created_at timestamptz not null default now()
);

-- ============================================================
-- TABLES — PROFESSIONNEL
-- ============================================================

-- Le SIRET appartient à l'ENTREPRISE, jamais à profiles. country_code permet
-- un professionnel hors France (registration_number remplace alors le SIRET,
-- aucun des deux n'est rendu obligatoire au niveau table : la validation de
-- format se fait application-side avant insertion, la contrainte ci-dessous
-- ne fait qu'empêcher un SIRET FR manifestement invalide d'être stocké).
create table professional_accounts (
  id uuid primary key default gen_random_uuid(),
  created_by uuid not null default auth.uid() references auth.users(id),
  legal_name text not null,               -- raison sociale
  trade_name text,                        -- nom commercial, facultatif
  country_code text not null default 'FR',
  siret text,                             -- 14 chiffres normalisés (sans espaces), France uniquement
  registration_number text,               -- immatriculation étrangère, si country_code <> 'FR'
  address_line1 text,
  address_line2 text,
  postal_code text,
  city text,
  activity_type text check (activity_type in (
    'conciergerie','camping','gestionnaire_mobilhome',
    'location_saisonniere','agence','autre'
  )),
  phone text,
  verification_status text not null default 'UNVERIFIED'
    check (verification_status in ('UNVERIFIED','PENDING','NOT_FOUND','SERVICE_UNAVAILABLE','VERIFIED')),
  verified_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint siret_format_fr check (
    country_code <> 'FR' or siret is null or siret ~ '^[0-9]{14}$'
  )
);

-- Empêche deux comptes entreprise indépendants sur le même SIRET français.
-- C'est cette contrainte — pas une fonction de lookup publique — qui protège
-- contre les doublons : voir la note "siret_exists" plus bas pour pourquoi
-- aucune fonction de vérification publique n'est ajoutée en Phase A.
create unique index idx_professional_accounts_siret
  on professional_accounts(siret) where siret is not null;

-- Lien entre un utilisateur et un compte professionnel. "role" ici est le
-- rôle DANS l'entreprise (owner/member) — distinct de profiles.global_role
-- qui est le type de compte global (customer/professional/admin). Prépare
-- le multi-utilisateur par entreprise sans construire l'interface d'invitation
-- maintenant.
create table professional_members (
  id uuid primary key default gen_random_uuid(),
  professional_account_id uuid not null references professional_accounts(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  role text not null default 'owner' check (role in ('owner','member')),
  created_at timestamptz not null default now(),
  unique (professional_account_id, user_id)
);

create table properties (
  id uuid primary key default gen_random_uuid(),
  professional_account_id uuid not null references professional_accounts(id) on delete cascade,
  reference text not null,
  name text,
  address text not null,
  postal_code text,
  city text,
  property_type text not null check (property_type in (
    'location_saisonniere','appartement','maison_villa','mobil_home','chalet','autre'
  )),
  access_notes text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- ============================================================
-- TABLES — CATALOGUE (source unique de vérité pour les prestations)
-- ============================================================
-- Objectif : un seul endroit qui pilote nom / catégorie / prix / durée /
-- disponibilité / type de clientèle, lu par la réservation, les tarifs
-- affichés et la recherche. Le contenu marketing (textes longs du Hero,
-- bullets descriptifs déjà écrits dans le frontend) reste dans le frontend :
-- cette table ne devient pas un CMS, juste la donnée métier nécessaire à la
-- réservation et à l'affichage des prix.
--
-- Modèle mixte assumé : certains services sont vendus directement (prix/
-- durée portés par la ligne "services"), d'autres se déclinent en plusieurs
-- formules (prix/durée portés par "service_packs", le service parent n'a
-- alors pas de prix propre). Les deux ne sont jamais renseignés en même
-- temps pour un même service — voir contrainte plus bas.
create table services (
  id uuid primary key default gen_random_uuid(),
  slug text not null unique,              -- reprend l'identifiant frontend actuel (ex. 'chauffage-depannage')
  category text not null check (category in ('climatisation','chauffage','plomberie','multi','pro')),
  customer_type text not null check (customer_type in ('particulier','professionnel')),
  name text not null,
  description text,
  booking_type text not null default 'DIRECT_BOOKING'
    check (booking_type in ('DIRECT_BOOKING','QUOTE_REQUEST')),
  base_price_cents integer,               -- null si le service se décline uniquement via service_packs
  duration_minutes integer,               -- idem
  is_active boolean not null default true,
  sort_order integer not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint services_price_requires_duration check (
    (base_price_cents is null) = (duration_minutes is null)
  )
);

create table service_packs (
  id uuid primary key default gen_random_uuid(),
  service_id uuid not null references services(id) on delete cascade,
  slug text not null unique,              -- reprend l'identifiant frontend actuel (ex. 'clim-essentiel')
  name text not null,
  description text,
  price_cents integer not null,           -- "à partir de" pour les prestations QUOTE_REQUEST : voir booking_type du service parent
  duration_minutes integer not null,
  is_featured boolean not null default false,
  is_active boolean not null default true,
  sort_order integer not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- ============================================================
-- TABLES — COMMUNES (réservations, interventions, devis, factures)
-- ============================================================

create table bookings (
  id uuid primary key default gen_random_uuid(),
  reference text not null unique,               -- ex. SM-2026-XXXX
  customer_user_id uuid references auth.users(id) on delete set null,
  professional_account_id uuid references professional_accounts(id) on delete set null,
  property_id uuid references properties(id) on delete set null,               -- si professionnel
  customer_address_id uuid references customer_addresses(id) on delete set null, -- si particulier connecté
  equipment_id uuid references customer_equipment(id) on delete set null,      -- optionnel, particulier
  guest_name text,
  guest_email text,
  guest_phone text,
  guest_address text,                            -- si réservation sans compte

  service_id uuid not null references services(id),
  service_pack_id uuid references service_packs(id),

  date date not null,
  start_time time not null,
  status text not null default 'PENDING' check (status in (
    'PENDING','CONFIRMED','IN_PROGRESS','COMPLETED','CANCELLED','NO_SHOW'
  )),

  -- Snapshots commerciaux : le prix/durée AU MOMENT de la réservation.
  -- services/service_packs représentent le tarif ACTUEL ; une réservation
  -- déjà prise ne doit jamais changer de prix ou de durée si le catalogue
  -- évolue ensuite.
  service_duration_minutes integer not null,
  service_price_cents integer not null,
  travel_fee_cents integer not null default 0,
  discount_cents integer not null default 0,
  total_cents integer not null,

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint bookings_single_owner check (
    not (customer_user_id is not null and professional_account_id is not null)
  ),
  constraint bookings_has_an_owner check (
    customer_user_id is not null
    or professional_account_id is not null
    or (guest_email is not null and guest_name is not null)
  )
);

-- Ce qui a RÉELLEMENT été fait, distinct de la réservation elle-même.
-- Sert à la fois le compte-rendu d'entretien particulier et le Check pro
-- (check_type reste nul pour un particulier).
create table interventions (
  id uuid primary key default gen_random_uuid(),
  booking_id uuid not null references bookings(id) on delete cascade,
  check_type text check (check_type in ('EXPRESS','COMPLET','PREMIUM')),
  performed_at timestamptz,
  technician_name text,
  created_at timestamptz not null default now()
);

create table intervention_items (
  id uuid primary key default gen_random_uuid(),
  intervention_id uuid not null references interventions(id) on delete cascade,
  name text not null,                            -- "Nettoyage filtres", "Plomberie", ...
  status text not null check (status in ('FUNCTIONAL','WATCH','INTERVENTION_RECOMMENDED')),
  observation text,
  visibility text not null default 'customer_visible'
    check (visibility in ('customer_visible','internal_only'))
);

-- Bucket Storage correspondant à créer manuellement (privé) : voir les
-- instructions transmises séparément. storage_path pointe vers ce bucket,
-- jamais une URL publique directe.
create table intervention_photos (
  id uuid primary key default gen_random_uuid(),
  intervention_item_id uuid not null references intervention_items(id) on delete cascade,
  storage_path text not null,
  created_at timestamptz not null default now()
);

create table quotes (
  id uuid primary key default gen_random_uuid(),
  customer_user_id uuid references auth.users(id) on delete set null,
  professional_account_id uuid references professional_accounts(id) on delete set null,
  booking_id uuid references bookings(id) on delete set null,
  reference text not null unique,
  status text not null default 'DRAFT' check (status in (
    'DRAFT','SENT','ACCEPTED','REFUSED','EXPIRED'
  )),
  subtotal_cents integer not null,
  travel_fee_cents integer not null default 0,
  discount_cents integer not null default 0,
  total_cents integer not null,
  created_at timestamptz not null default now(),
  constraint quotes_single_owner check (
    not (customer_user_id is not null and professional_account_id is not null)
  ),
  constraint quotes_has_an_owner check (
    customer_user_id is not null or professional_account_id is not null
  )
);

-- Structure préparée uniquement : pas de logique de facturation légale à ce
-- stade (numérotation légale, TVA, etc. seront traitées comme un sujet séparé).
create table invoices (
  id uuid primary key default gen_random_uuid(),
  customer_user_id uuid references auth.users(id) on delete set null,
  professional_account_id uuid references professional_accounts(id) on delete set null,
  quote_id uuid references quotes(id) on delete set null,
  reference text not null unique,
  status text not null default 'DRAFT' check (status in ('DRAFT','ISSUED','PAID','CANCELLED')),
  total_cents integer not null,
  created_at timestamptz not null default now(),
  constraint invoices_single_owner check (
    not (customer_user_id is not null and professional_account_id is not null)
  ),
  constraint invoices_has_an_owner check (
    customer_user_id is not null or professional_account_id is not null
  )
);

-- Événements réellement utiles uniquement — pas de duplication d'adresses,
-- téléphones ou contenu de documents ici (voir rapport, point 13).
create table audit_logs (
  id uuid primary key default gen_random_uuid(),
  actor_user_id uuid references auth.users(id) on delete set null,
  action text not null,           -- ex. 'property.create', 'booking.status_change', 'account.claim'
  entity text not null,
  entity_id uuid,
  created_at timestamptz not null default now()
);

-- ============================================================
-- INDEX
-- ============================================================
create index idx_customer_addresses_user on customer_addresses(customer_user_id);
create index idx_customer_equipment_user on customer_equipment(customer_user_id);
create index idx_professional_members_account on professional_members(professional_account_id);
create index idx_professional_members_user on professional_members(user_id);
create index idx_properties_account on properties(professional_account_id);
create index idx_services_category on services(category);
create index idx_service_packs_service on service_packs(service_id);
create index idx_bookings_customer on bookings(customer_user_id);
create index idx_bookings_account on bookings(professional_account_id);
create index idx_bookings_property on bookings(property_id);
create index idx_bookings_date on bookings(date);
create index idx_bookings_service on bookings(service_id);
create index idx_interventions_booking on interventions(booking_id);
create index idx_intervention_items_intervention on intervention_items(intervention_id);
create index idx_quotes_customer on quotes(customer_user_id);
create index idx_quotes_account on quotes(professional_account_id);
create index idx_invoices_customer on invoices(customer_user_id);
create index idx_invoices_account on invoices(professional_account_id);

-- ============================================================
-- FONCTIONS UTILITAIRES (SECURITY DEFINER, durcies)
-- ============================================================
-- Les deux fonctions ci-dessous ne font que lire l'identité de l'appelant
-- (auth.uid()) — elles ne prennent aucun paramètre permettant d'interroger
-- les droits d'un AUTRE utilisateur, donc leur exécution large (anon +
-- authenticated) ne crée pas de fuite de privilège. search_path est fixé
-- explicitement pour empêcher un détournement par un objet de même nom
-- placé plus tôt dans un search_path non maîtrisé (risque classique des
-- fonctions SECURITY DEFINER en PostgreSQL).

create or replace function is_admin()
returns boolean
language sql
security definer
set search_path = public
stable
as $$
  select exists (
    select 1 from profiles
    where user_id = auth.uid() and global_role = 'admin'
  );
$$;
revoke all on function is_admin() from public;
grant execute on function is_admin() to authenticated, anon;

create or replace function my_professional_account_ids()
returns setof uuid
language sql
security definer
set search_path = public
stable
as $$
  select professional_account_id from professional_members where user_id = auth.uid();
$$;
revoke all on function my_professional_account_ids() from public;
grant execute on function my_professional_account_ids() to authenticated, anon;

-- Note "siret_exists" (volontairement absente) : une fonction publique de
-- lookup par SIRET a été envisagée puis écartée pour la Phase A. L'index
-- unique partiel ci-dessus (idx_professional_accounts_siret) empêche déjà
-- tout doublon au niveau base — l'INSERT échoue simplement avec une erreur
-- de contrainte unique. Le parcours "cette entreprise a peut-être déjà un
-- espace" sera construit plus tard dans l'Edge Function qui fera la vraie
-- vérification SIRET externe : elle pourra intercepter cette erreur
-- server-side et répondre proprement, sans exposer de fonction de lookup
-- interrogeable librement par n'importe quel visiteur (ce qui aurait permis
-- de tester en masse si des entreprises précises sont déjà clientes —
-- un risque d'énumération inutile pour un bénéfice qu'un simple index suffit
-- déjà à couvrir).

-- ============================================================
-- ROW LEVEL SECURITY
-- ============================================================
alter table profiles enable row level security;
alter table customer_profiles enable row level security;
alter table customer_addresses enable row level security;
alter table customer_equipment enable row level security;
alter table professional_accounts enable row level security;
alter table professional_members enable row level security;
alter table properties enable row level security;
alter table services enable row level security;
alter table service_packs enable row level security;
alter table bookings enable row level security;
alter table interventions enable row level security;
alter table intervention_items enable row level security;
alter table intervention_photos enable row level security;
alter table quotes enable row level security;
alter table invoices enable row level security;
alter table audit_logs enable row level security;

-- ---- profiles ----
-- Le rôle global n'est JAMAIS modifiable par l'utilisateur lui-même : le
-- check de l'insert interdit 'admin', et il n'existe AUCUNE policy update
-- ouverte à l'utilisateur — seule "profiles: admin update" existe, réservée
-- à is_admin(). Attribuer le rôle admin reste un geste manuel explicite
-- (SQL editor, par un admin déjà existant), jamais un chemin applicatif.
create policy "profiles: self or admin read" on profiles
  for select using (user_id = auth.uid() or is_admin());
create policy "profiles: self insert" on profiles
  for insert with check (user_id = auth.uid() and global_role in ('customer','professional'));
create policy "profiles: admin update" on profiles
  for update using (is_admin());

-- ---- customer_profiles / customer_addresses / customer_equipment ----
create policy "customer_profiles: self or admin" on customer_profiles
  for all using (user_id = auth.uid() or is_admin())
  with check (user_id = auth.uid());

create policy "customer_addresses: self or admin" on customer_addresses
  for all using (customer_user_id = auth.uid() or is_admin())
  with check (customer_user_id = auth.uid());

create policy "customer_equipment: self or admin" on customer_equipment
  for all using (customer_user_id = auth.uid() or is_admin())
  with check (customer_user_id = auth.uid());

-- ---- professional_accounts ----
-- Lecture/écriture réservées aux membres du compte ; création libre à
-- l'inscription (au moment de l'insert, aucun professional_members n'existe
-- encore pour relier l'utilisateur au compte qu'il crée).
create policy "pro accounts: members or admin read" on professional_accounts
  for select using (id in (select my_professional_account_ids()) or is_admin());
-- CORRECTIF (revue de sécurité) : la version précédente n'exigeait que
-- auth.uid() is not null, sans lier la ligne à son créateur. Combinée à
-- l'ancienne policy d'insert sur professional_members (qui ne vérifiait que
-- user_id = auth.uid(), sans borner professional_account_id), un attaquant
-- authentifié aurait pu s'insérer comme "owner" dans N'IMPORTE QUEL compte
-- professionnel existant en devinant/obtenant son UUID. created_by ferme
-- ce trou : with check impose que la ligne créée s'auto-attribue bien au
-- créateur réel.
-- Le "auth.uid() is not null" a été retiré (redondant : created_by est une
-- colonne not null, donc "created_by = auth.uid()" ne peut de toute façon
-- jamais être vrai si auth.uid() est null). Retiré aussi parce qu'en test
-- réel (vraie session, vrai appel REST, pas de simulation SQL), la présence
-- littérale de cette clause faisait échouer l'insertion malgré un
-- auth.uid() confirmé non-null par ailleurs sur la même session — même
-- symptôme observé sur l'ancienne policy d'insert de audit_logs. Cause
-- exacte non identifiée ; corrigé en alignant sur le style des policies qui,
-- elles, fonctionnaient de façon fiable en conditions réelles (ex.
-- customer_addresses : "customer_user_id = auth.uid()" seul).
create policy "pro accounts: authenticated can create" on professional_accounts
  for insert with check (created_by = auth.uid());
create policy "pro accounts: members or admin update" on professional_accounts
  for update using (id in (select my_professional_account_ids()) or is_admin())
  with check (id in (select my_professional_account_ids()) or is_admin());

-- ---- professional_members ----
-- CORRECTIF (revue de sécurité) : l'insert n'autorise plus qu'un seul cas
-- précis — le créateur d'un compte professionnel (professional_accounts.
-- created_by) s'y insère lui-même comme owner. Il ne peut pas choisir un
-- professional_account_id arbitraire (contrairement à la version précédente,
-- où seul user_id = auth.uid() était vérifié) ni s'ajouter une seconde fois
-- (la contrainte unique(professional_account_id, user_id) l'en empêche), ni
-- ajouter quelqu'un d'autre. Rejoindre une entreprise déjà existante ou
-- inviter un collègue nécessitera un parcours d'invitation dédié (Edge
-- Function), volontairement non construit ici : cette policy ne le permet
-- donc pas du tout pour l'instant, ce qui est le comportement sûr par défaut.
create policy "pro members: peers or admin read" on professional_members
  for select using (
    professional_account_id in (select my_professional_account_ids()) or is_admin()
  );
create policy "pro members: creator claims own new account as owner" on professional_members
  for insert with check (
    role = 'owner'
    and user_id = auth.uid()
    and professional_account_id in (
      select id from professional_accounts where created_by = auth.uid()
    )
  );

-- ---------------------------------------------------------------------
-- create_professional_account() — contournement d'une anomalie RLS non
-- résolue sur l'INSERT direct dans professional_accounts.
--
-- Constat (vérifié en conditions réelles : vraie session, vrai appel REST,
-- pas de simulation SQL) : un utilisateur authentifié ne peut PAS créer sa
-- propre ligne professional_accounts directement depuis le client, même
-- avec la policy la plus simple possible (created_by = auth.uid(), même
-- forme que customer_user_id = auth.uid() sur customer_addresses, qui elle
-- fonctionne). Testé et éliminé comme causes possibles : policy en base
-- différente du fichier, cache de schéma PostgREST périmé, droits GRANT
-- table manquants, policy restrictive cachée, cache SDK navigateur, compte
-- de test corrompu, drapeaux RLS pg_class anormaux. Cause exacte non
-- identifiée (même symptôme que l'ancienne policy d'insert de audit_logs).
--
-- Cette fonction SECURITY DEFINER contourne le problème en s'exécutant avec
-- les privilèges de son propriétaire plutôt que ceux du client, tout en
-- restant sûre : elle ignore tout ce que le client pourrait prétendre sur
-- son identité et fixe elle-même created_by/user_id à partir de auth.uid()
-- (jamais un paramètre). Elle fait aussi les 3 insertions (compte + membre
-- owner + profil) de façon atomique — si une étape échoue, tout est annulé,
-- contrairement à l'ancienne chaîne d'appels côté client qui pouvait laisser
-- un compte orphelin en cas d'échec partiel (exactement ce qui a été
-- constaté pendant les tests : un profil "customer" orphelin sans entreprise
-- associée).
create or replace function create_professional_account(
  p_legal_name text,
  p_activity_type text default null,
  p_phone text default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_account_id uuid;
begin
  if v_uid is null then
    raise exception 'Authentification requise.';
  end if;

  if exists (select 1 from profiles where user_id = v_uid) then
    raise exception 'Ce compte a déjà un profil.';
  end if;

  insert into professional_accounts (created_by, legal_name, activity_type, phone)
  values (v_uid, p_legal_name, p_activity_type, p_phone)
  returning id into v_account_id;

  insert into professional_members (professional_account_id, user_id, role)
  values (v_account_id, v_uid, 'owner');

  insert into profiles (user_id, email, global_role)
  select v_uid, email, 'professional' from auth.users where id = v_uid;

  return v_account_id;
end;
$$;
revoke all on function create_professional_account(text, text, text) from public;
grant execute on function create_professional_account(text, text, text) to authenticated;

-- ---- properties ----
create policy "properties: account members or admin" on properties
  for all using (
    professional_account_id in (select my_professional_account_ids()) or is_admin()
  ) with check (
    professional_account_id in (select my_professional_account_ids())
  );

-- ---- services / service_packs ----
-- Catalogue public en lecture (nécessaire à l'affichage des tarifs et à la
-- réservation par un visiteur non connecté) ; écriture réservée à l'admin.
create policy "services: public read active, admin read all" on services
  for select using (is_active or is_admin());
create policy "services: admin write" on services
  for insert with check (is_admin());
create policy "services: admin update" on services
  for update using (is_admin());
create policy "services: admin delete" on services
  for delete using (is_admin());

create policy "service_packs: public read active, admin read all" on service_packs
  for select using (is_active or is_admin());
create policy "service_packs: admin write" on service_packs
  for insert with check (is_admin());
create policy "service_packs: admin update" on service_packs
  for update using (is_admin());
create policy "service_packs: admin delete" on service_packs
  for delete using (is_admin());

-- ---- bookings ----
-- Scindée en policies distinctes (plutôt qu'un seul "for all") car l'INSERT
-- doit accepter une réservation invité (sans compte), alors que SELECT/UPDATE/
-- DELETE ne doivent JAMAIS être accessibles via une simple correspondance
-- d'e-mail invité — une réservation invité reste illisible par l'API cliente
-- tant qu'elle n'a pas été rattachée à un compte par la procédure serveur
-- sécurisée décrite dans le rapport (point 10).
create policy "bookings: owner or admin read" on bookings
  for select using (
    customer_user_id = auth.uid()
    or professional_account_id in (select my_professional_account_ids())
    or is_admin()
  );
create policy "bookings: create own or guest" on bookings
  for insert
  with check (
    (customer_user_id is not null and customer_user_id = auth.uid())
    or (professional_account_id is not null and professional_account_id in (select my_professional_account_ids()))
    or (customer_user_id is null and professional_account_id is null
        and guest_email is not null and guest_name is not null)
  );
create policy "bookings: owner or admin update" on bookings
  for update using (
    customer_user_id = auth.uid()
    or professional_account_id in (select my_professional_account_ids())
    or is_admin()
  ) with check (
    customer_user_id = auth.uid()
    or professional_account_id in (select my_professional_account_ids())
    or is_admin()
  );
create policy "bookings: owner or admin delete" on bookings
  for delete using (
    customer_user_id = auth.uid()
    or professional_account_id in (select my_professional_account_ids())
    or is_admin()
  );

-- ---- interventions (accès via le booking) ----
create policy "interventions: via booking owner" on interventions
  for all using (
    booking_id in (
      select id from bookings
      where customer_user_id = auth.uid()
         or professional_account_id in (select my_professional_account_ids())
    )
    or is_admin()
  ) with check (
    booking_id in (
      select id from bookings
      where customer_user_id = auth.uid()
         or professional_account_id in (select my_professional_account_ids())
    )
  );

-- ---- intervention_items ----
-- Un client (customer) ne voit jamais les lignes "internal_only", même sur
-- ses propres réservations. Le professionnel propriétaire et l'admin voient tout.
create policy "intervention_items: customer sees visible only" on intervention_items
  for select using (
    visibility = 'customer_visible'
    and intervention_id in (
      select i.id from interventions i
      join bookings b on b.id = i.booking_id
      where b.customer_user_id = auth.uid()
    )
  );
create policy "intervention_items: pro or admin full access" on intervention_items
  for all using (
    is_admin()
    or intervention_id in (
      select i.id from interventions i
      join bookings b on b.id = i.booking_id
      where b.professional_account_id in (select my_professional_account_ids())
    )
  ) with check (
    is_admin()
    or intervention_id in (
      select i.id from interventions i
      join bookings b on b.id = i.booking_id
      where b.professional_account_id in (select my_professional_account_ids())
    )
  );

-- ---- intervention_photos (même logique que intervention_items, via l'item) ----
create policy "intervention_photos: customer sees visible only" on intervention_photos
  for select using (
    intervention_item_id in (
      select ii.id from intervention_items ii
      join interventions i on i.id = ii.intervention_id
      join bookings b on b.id = i.booking_id
      where ii.visibility = 'customer_visible' and b.customer_user_id = auth.uid()
    )
  );
create policy "intervention_photos: pro or admin full access" on intervention_photos
  for all using (
    is_admin()
    or intervention_item_id in (
      select ii.id from intervention_items ii
      join interventions i on i.id = ii.intervention_id
      join bookings b on b.id = i.booking_id
      where b.professional_account_id in (select my_professional_account_ids())
    )
  ) with check (
    is_admin()
    or intervention_item_id in (
      select ii.id from intervention_items ii
      join interventions i on i.id = ii.intervention_id
      join bookings b on b.id = i.booking_id
      where b.professional_account_id in (select my_professional_account_ids())
    )
  );

-- ---- quotes / invoices ----
-- Pas de chemin "invité" ici (contrairement à bookings) : un devis/une
-- facture n'existe que rattaché à un compte connu, jamais à un simple e-mail.
create policy "quotes: owner customer, owner pro, or admin" on quotes
  for all using (
    customer_user_id = auth.uid()
    or professional_account_id in (select my_professional_account_ids())
    or is_admin()
  ) with check (
    customer_user_id = auth.uid()
    or professional_account_id in (select my_professional_account_ids())
  );

create policy "invoices: owner customer, owner pro, or admin" on invoices
  for all using (
    customer_user_id = auth.uid()
    or professional_account_id in (select my_professional_account_ids())
    or is_admin()
  ) with check (
    customer_user_id = auth.uid()
    or professional_account_id in (select my_professional_account_ids())
  );

-- ---- audit_logs : lecture admin uniquement, AUCUNE écriture cliente ----
-- Un utilisateur authentifié pouvait auparavant insérer une ligne avec
-- n'importe quel actor_user_id (le check ne vérifiait que auth.uid() is not
-- null, jamais que actor_user_id = auth.uid()) : usurpation d'auteur possible
-- dans le journal d'audit. Corrigé en retirant toute policy d'insertion
-- cliente : plus aucun chemin RLS ne permet d'écrire dans cette table. Les
-- futurs logs seront créés uniquement par des fonctions serveur
-- SECURITY DEFINER (créées avec chaque action métier concernée), qui fixeront
-- elles-mêmes actor_user_id à partir de auth.uid() et ne sont pas soumises à
-- ces policies pour leurs propres écritures.
create policy "audit_logs: admin read" on audit_logs
  for select using (is_admin());

-- ============================================================
-- TRIGGERS DE PROTECTION (revue de sécurité)
-- ============================================================
-- Les policies UPDATE ci-dessus autorisent légitimement un propriétaire à
-- modifier SA PROPRE ligne (ex. un pro corrige l'adresse de son entreprise,
-- un client annule son propre rendez-vous). Mais RLS ne peut pas restreindre
-- l'accès colonne par colonne : sans ce qui suit, ce même propriétaire
-- pourrait aussi, dans le même UPDATE, s'auto-déclarer "VERIFIED" ou modifier
-- le prix déjà accepté d'une réservation passée. Ces triggers ramènent
-- silencieusement les colonnes sensibles à leur valeur précédente lorsque
-- l'auteur n'est ni admin ni le service_role (donc pas une future Edge
-- Function authentifiée par la clé serveur).

create or replace function protect_verification_fields()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if not (is_admin() or auth.role() = 'service_role') then
    new.verification_status := old.verification_status;
    new.verified_at := old.verified_at;
  end if;
  return new;
end;
$$;
revoke all on function protect_verification_fields() from public;

create trigger trg_protect_verification
  before update on professional_accounts
  for each row execute function protect_verification_fields();

-- Un client ou un professionnel possède bien SA réservation (policy update
-- déjà en place), mais ne doit jamais pouvoir changer, via un simple appel
-- client, le prix accepté, la durée retenue ou le statut de cette réservation
-- — ce sont exactement les valeurs que la Phase E (réservations réelles)
-- devra calculer et faire évoluer côté serveur (Edge Function / RPC dédiée),
-- jamais depuis le navigateur. Ce trigger verrouille ces colonnes dès
-- maintenant, avant même que la Phase E n'existe.
create or replace function protect_booking_financial_fields()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if not (is_admin() or auth.role() = 'service_role') then
    new.service_price_cents := old.service_price_cents;
    new.travel_fee_cents := old.travel_fee_cents;
    new.discount_cents := old.discount_cents;
    new.total_cents := old.total_cents;
    new.service_duration_minutes := old.service_duration_minutes;
    new.status := old.status;
  end if;
  return new;
end;
$$;
revoke all on function protect_booking_financial_fields() from public;

create trigger trg_protect_booking_financials
  before update on bookings
  for each row execute function protect_booking_financial_fields();

-- Même logique pour les devis/factures : le montant et le statut
-- (ex. passer soi-même un devis en 'ACCEPTED' ou une facture en 'PAID')
-- ne doivent jamais changer via un UPDATE client direct.
create or replace function protect_quote_invoice_fields()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if not (is_admin() or auth.role() = 'service_role') then
    new.status := old.status;
    new.subtotal_cents := old.subtotal_cents;
    new.travel_fee_cents := old.travel_fee_cents;
    new.discount_cents := old.discount_cents;
    new.total_cents := old.total_cents;
  end if;
  return new;
end;
$$;
revoke all on function protect_quote_invoice_fields() from public;

create trigger trg_protect_quote_fields
  before update on quotes
  for each row execute function protect_quote_invoice_fields();

create or replace function protect_invoice_amount_fields()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if not (is_admin() or auth.role() = 'service_role') then
    new.status := old.status;
    new.total_cents := old.total_cents;
  end if;
  return new;
end;
$$;
revoke all on function protect_invoice_amount_fields() from public;

create trigger trg_protect_invoice_fields
  before update on invoices
  for each row execute function protect_invoice_amount_fields();

-- ============================================================
-- CATALOGUE INITIAL — reprend EXACTEMENT les prix/durées actuellement dans
-- le frontend (tableau SERVICES et packs #pro), aucun tarif modifié.
-- Vérifié ligne à ligne contre le HTML statique des tarifs : aucune
-- divergence trouvée (voir rapport, section "Divergences tarifaires").
-- Montants en centimes entiers.
-- ============================================================

-- ---- Climatisation ----
-- Installation + entretien/nettoyage/contrôle. Positionnement commercial
-- validé : PAS de dépannage climatisation, PAS d'intervention sur le
-- circuit frigorifique (réparation, recherche de fuite, recharge de
-- fluide) — catalogue volontairement limité en conséquence.
--
-- Installation = QUOTE_REQUEST, sans service_packs et sans prix de
-- catalogue : une pose nécessite une étude sur site (puissance, unités,
-- configuration) donc le prix dépend du projet. base_price_cents et
-- duration_minutes restent NULL (colonnes non listées ci-dessous, donc
-- NULL par défaut — voir contrainte services_price_requires_duration qui
-- impose que les deux soient renseignés ensemble ou NULL ensemble). On
-- n'invente pas un tarif fixe à 0 € pour un service dont le prix réel varie.
insert into services (slug, category, customer_type, name, booking_type, sort_order) values
  ('clim-installation', 'climatisation', 'particulier', 'Installation climatisation', 'QUOTE_REQUEST', 5);

insert into services (slug, category, customer_type, name, booking_type, sort_order) values
  ('clim-entretien', 'climatisation', 'particulier', 'Entretien climatisation', 'DIRECT_BOOKING', 10);

insert into service_packs (service_id, slug, name, price_cents, duration_minutes, is_featured, sort_order)
select id, 'clim-essentiel', 'Pack Essentiel', 5900, 60, false, 1 from services where slug = 'clim-entretien'
union all
select id, 'clim-confort', 'Pack Confort', 7900, 90, true, 2 from services where slug = 'clim-entretien'
union all
select id, 'clim-premium', 'Pack Premium', 12900, 120, false, 3 from services where slug = 'clim-entretien';

-- ---- Chauffage ----
insert into services (slug, category, customer_type, name, booking_type, sort_order) values
  ('chauffage-chaudiere-gaz', 'chauffage', 'particulier', 'Entretien chaudière gaz', 'DIRECT_BOOKING', 30),
  ('chauffage-chaudiere-fioul', 'chauffage', 'particulier', 'Entretien chaudière fioul', 'DIRECT_BOOKING', 40);

insert into service_packs (service_id, slug, name, price_cents, duration_minutes, is_featured, sort_order)
select id, 'chauffage-chaudiere-gaz-essentiel', 'Pack Essentiel', 9900, 60, false, 1 from services where slug = 'chauffage-chaudiere-gaz'
union all
select id, 'chauffage-chaudiere-gaz-confort', 'Pack Confort', 12900, 90, false, 2 from services where slug = 'chauffage-chaudiere-gaz'
union all
select id, 'chauffage-chaudiere-gaz-premium', 'Pack Premium', 16900, 120, false, 3 from services where slug = 'chauffage-chaudiere-gaz'
union all
select id, 'chauffage-chaudiere-fioul-essentiel', 'Pack Essentiel', 12900, 60, false, 1 from services where slug = 'chauffage-chaudiere-fioul'
union all
select id, 'chauffage-chaudiere-fioul-confort', 'Pack Confort', 16900, 90, false, 2 from services where slug = 'chauffage-chaudiere-fioul'
union all
select id, 'chauffage-chaudiere-fioul-premium', 'Pack Premium', 21900, 120, false, 3 from services where slug = 'chauffage-chaudiere-fioul';

insert into services (slug, category, customer_type, name, booking_type, base_price_cents, duration_minutes, sort_order) values
  ('chauffage-depannage', 'chauffage', 'particulier', 'Dépannage chauffage', 'DIRECT_BOOKING', 7500, 90, 41),
  ('chauffage-radiateur', 'chauffage', 'particulier', 'Remplacement radiateur', 'DIRECT_BOOKING', 15000, 90, 42),
  ('chauffage-circulateur', 'chauffage', 'particulier', 'Remplacement circulateur', 'DIRECT_BOOKING', 20833, 90, 43),
  ('chauffage-vase', 'chauffage', 'particulier', 'Remplacement vase d''expansion', 'DIRECT_BOOKING', 23333, 90, 44),
  ('chauffage-purge', 'chauffage', 'particulier', 'Purge complète du circuit (chaudière fioul)', 'DIRECT_BOOKING', 7500, 60, 45),
  ('chauffage-pression', 'chauffage', 'particulier', 'Remise en pression du circuit (chaudière fioul)', 'DIRECT_BOOKING', 5000, 45, 46);

-- ---- Plomberie ----
insert into services (slug, category, customer_type, name, booking_type, base_price_cents, duration_minutes, sort_order) values
  ('plomberie-depannage', 'plomberie', 'particulier', 'Forfait dépannage plomberie', 'DIRECT_BOOKING', 5000, 60, 50),
  ('plomberie-fuite', 'plomberie', 'particulier', 'Forfait recherche de fuite', 'DIRECT_BOOKING', 7500, 60, 51),
  ('plomberie-robinet', 'plomberie', 'particulier', 'Remplacement robinet évier', 'DIRECT_BOOKING', 10000, 60, 52),
  ('plomberie-wc-mecanisme', 'plomberie', 'particulier', 'Remplacement mécanisme WC', 'DIRECT_BOOKING', 8333, 60, 53),
  ('plomberie-chasse-eau', 'plomberie', 'particulier', 'Remplacement chasse d''eau complète', 'DIRECT_BOOKING', 15000, 90, 54),
  ('plomberie-debouchage-evier', 'plomberie', 'particulier', 'Débouchage évier / lavabo', 'DIRECT_BOOKING', 7500, 60, 55),
  ('plomberie-debouchage-wc', 'plomberie', 'particulier', 'Débouchage WC', 'DIRECT_BOOKING', 10000, 60, 56),
  ('plomberie-seche-serviette', 'plomberie', 'particulier', 'Pose sèche-serviettes', 'DIRECT_BOOKING', 25000, 120, 57),
  ('plomberie-colonne-douche', 'plomberie', 'particulier', 'Pose colonne de douche', 'DIRECT_BOOKING', 16000, 90, 58),
  ('plomberie-paroi-douche', 'plomberie', 'particulier', 'Pose paroi de douche', 'DIRECT_BOOKING', 18000, 120, 59),
  ('plomberie-receveur', 'plomberie', 'particulier', 'Pose receveur de douche', 'DIRECT_BOOKING', 35000, 180, 60),
  ('plomberie-baignoire', 'plomberie', 'particulier', 'Pose baignoire', 'DIRECT_BOOKING', 50000, 240, 61);

-- ---- Multi-services / devis ----
insert into services (slug, category, customer_type, name, booking_type, base_price_cents, duration_minutes, sort_order) values
  ('multi', 'multi', 'particulier', 'Entretien Multi-Services', 'DIRECT_BOOKING', 15000, 120, 70),
  ('devis', 'multi', 'particulier', 'Devis gratuit', 'QUOTE_REQUEST', 0, 60, 71);

-- ---- Check technique professionnel ----
insert into services (slug, category, customer_type, name, booking_type, sort_order) values
  ('pro-check', 'pro', 'professionnel', 'Check Technique', 'DIRECT_BOOKING', 80);

insert into service_packs (service_id, slug, name, price_cents, duration_minutes, is_featured, sort_order)
select id, 'pro-check-express', 'Check Express', 6900, 45, false, 1 from services where slug = 'pro-check'
union all
select id, 'pro-check-complet', 'Check Complet', 9900, 75, true, 2 from services where slug = 'pro-check'
union all
select id, 'pro-check-premium', 'Check Premium', 14900, 100, false, 3 from services where slug = 'pro-check';

-- ============================================================
-- RÉSERVATION RÉELLE — create_booking() + anti-double-réservation
-- ============================================================
-- create_booking() — SECURITY DEFINER, même patron durci que
-- create_professional_account() : le prix/la durée/le total ne sont JAMAIS
-- des paramètres (calculés exclusivement depuis services/service_packs),
-- l'identité vient exclusivement de auth.uid() (jamais un paramètre).
--
-- Portée volontairement limitée à cette étape :
--   - réservation invité (guest_*) : non gérée ici ;
--   - frais de déplacement réels : aucun calcul de distance/itinéraire réel
--     disponible côté serveur — fixés à 0, jamais un montant inventé ;
--   - remise (discount_cents) : non gérée ici (flux pro/multi-logements,
--     hors périmètre) ;
--   - commentaire libre du formulaire actuel : aucune colonne bookings ne
--     l'accueille, non repris ici.
create or replace function create_booking(
  p_service_slug text,
  p_date date,
  p_start_time time,
  p_service_pack_slug text default null,
  p_customer_address_id uuid default null,
  p_equipment_id uuid default null
)
returns table(booking_id uuid, reference text, total_cents integer)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_role text;
  v_service services%rowtype;
  v_pack service_packs%rowtype;
  v_service_pack_id uuid;
  v_price_cents integer;
  v_duration_minutes integer;
  v_total_cents integer;
  v_reference text;
  v_booking_id uuid;
begin
  if v_uid is null then
    raise exception 'Authentification requise pour réserver.';
  end if;

  select global_role into v_role from profiles where user_id = v_uid;
  if v_role is null then
    raise exception 'Profil introuvable pour ce compte.';
  end if;
  if v_role <> 'customer' then
    raise exception 'Cette fonction de réservation est réservée aux comptes particuliers.';
  end if;

  -- CORRECTIF (revue de sécurité, réservation réelle) : une réservation
  -- réelle doit obligatoirement être rattachée à une adresse d'intervention
  -- appartenant au client — plus de NULL toléré. L'adresse fournie est
  -- revérifiée ici (jamais fait confiance seule côté navigateur), car la
  -- fonction s'exécute avec des privilèges élevés qui contournent la RLS
  -- par nature de SECURITY DEFINER.
  if p_customer_address_id is null then
    raise exception 'Une adresse d''intervention est requise pour réserver.';
  end if;
  if not exists (
    select 1 from customer_addresses
    where id = p_customer_address_id and customer_user_id = v_uid
  ) then
    raise exception 'Adresse inconnue ou non rattachée à votre compte.';
  end if;

  if p_equipment_id is not null and not exists (
    select 1 from customer_equipment
    where id = p_equipment_id and customer_user_id = v_uid
  ) then
    raise exception 'Équipement inconnu ou non rattaché à votre compte.';
  end if;

  if p_date < current_date then
    raise exception 'Impossible de réserver une date déjà passée.';
  end if;

  select * into v_service from services where slug = p_service_slug;
  if not found then
    raise exception 'Prestation inconnue.';
  end if;
  if not v_service.is_active then
    raise exception 'Cette prestation n''est plus disponible.';
  end if;
  if v_service.booking_type <> 'DIRECT_BOOKING' then
    raise exception 'Cette prestation fonctionne uniquement sur devis et ne peut pas être réservée directement.';
  end if;

  if coalesce(p_service_pack_slug, '') <> '' then
    select * into v_pack from service_packs where slug = p_service_pack_slug;
    if not found then
      raise exception 'Formule inconnue.';
    end if;
    if not v_pack.is_active then
      raise exception 'Cette formule n''est plus disponible.';
    end if;
    if v_pack.service_id <> v_service.id then
      raise exception 'Cette formule ne correspond pas à la prestation demandée.';
    end if;
    v_price_cents := v_pack.price_cents;
    v_duration_minutes := v_pack.duration_minutes;
    v_service_pack_id := v_pack.id;
  else
    if v_service.base_price_cents is null then
      raise exception 'Cette prestation nécessite le choix d''une formule.';
    end if;
    v_price_cents := v_service.base_price_cents;
    v_duration_minutes := v_service.duration_minutes;
    v_service_pack_id := null;
  end if;

  v_total_cents := v_price_cents;

  v_reference := 'SM-' || to_char(now(), 'YYYY') || '-' ||
    upper(substr(md5(gen_random_uuid()::text), 1, 6));

  begin
    insert into bookings (
      reference, customer_user_id, customer_address_id, equipment_id,
      service_id, service_pack_id, date, start_time, status,
      service_duration_minutes, service_price_cents, travel_fee_cents, discount_cents, total_cents
    ) values (
      v_reference, v_uid, p_customer_address_id, p_equipment_id,
      v_service.id, v_service_pack_id, p_date, p_start_time, 'PENDING',
      v_duration_minutes, v_price_cents, 0, 0, v_total_cents
    ) returning id into v_booking_id;
  exception
    when exclusion_violation then
      raise exception 'Ce créneau vient d''être réservé. Choisissez un autre horaire.';
  end;

  return query select v_booking_id, v_reference, v_total_cents;
end;
$$;

revoke all on function create_booking(text, date, time, text, uuid, uuid) from public;
grant execute on function create_booking(text, date, time, text, uuid, uuid) to authenticated;
-- CORRECTIF (revue de sécurité, test réel) : sur ce projet, la création de la
-- fonction a accordé EXECUTE à `anon` malgré le `REVOKE ALL ... FROM PUBLIC`
-- ci-dessus (vérifié via information_schema.routine_privileges) — vraisembla-
-- blement un privilège par défaut du schéma public accordé automatiquement à
-- `anon`/`authenticated` à la création de toute fonction, que le REVOKE FROM
-- PUBLIC ne retire pas (il ne retire que le droit du pseudo-rôle PUBLIC, pas
-- un droit accordé séparément et directement à un rôle nommé). Aucune réser-
-- vation n'a pu être créée par un appelant anonyme (la vérification auth.uid()
-- interne tenait), mais la barrière de permission prévue en défense en
-- profondeur n'était pas en place. Corrigé explicitement ci-dessous ; ce
-- REVOKE nommé est nécessaire même après un simple REVOKE FROM PUBLIC.
revoke execute on function create_booking(text, date, time, text, uuid, uuid) from anon;

-- Anti-double-réservation : deux réservations actives ne doivent jamais
-- pouvoir occuper un créneau qui se chevauche, même en cas de validation
-- quasi simultanée par deux clients. Garantie atomique au niveau base
-- (contrainte d'exclusion GiST), pas une simple vérification JavaScript.
--
-- Pas besoin de l'extension btree_gist : la contrainte ne combine qu'une
-- seule colonne de type range (aucune colonne d'égalité, ex. un futur
-- technician_id, n'existe dans ce schéma — si un jour plusieurs techniciens
-- sont gérés séparément, il faudra alors une colonne dédiée ET btree_gist
-- pour combiner égalité + range).
--
-- Statuts bloquants : PENDING, CONFIRMED, IN_PROGRESS, COMPLETED.
-- CANCELLED et NO_SHOW ne bloquent pas (créneau considéré libre).
-- tsrange (pas tstzrange) : date/start_time n'ont aucune notion de fuseau
-- horaire dans ce schéma.
alter table bookings
  add constraint bookings_no_overlapping_slots
  exclude using gist (
    tsrange(
      (date + start_time),
      (date + start_time + (service_duration_minutes * interval '1 minute'))
    ) with &&
  )
  where (status in ('PENDING', 'CONFIRMED', 'IN_PROGRESS', 'COMPLETED'));

-- ============================================================
-- FIN — aucune autre donnée de test insérée volontairement (pas d'avis,
-- pas de compte, pas de réservation fictive : voir rapport point 14).
--
-- Pour créer ton propre compte admin après ta première inscription :
--   update profiles set global_role = 'admin' where email = 'ton-email@exemple.fr';
-- ============================================================
