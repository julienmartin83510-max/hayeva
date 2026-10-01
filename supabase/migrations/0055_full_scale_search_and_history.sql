-- ============================================================
-- Suppression de la dépendance au cache limité à 500 réservations
-- (adminBookingsCache) pour la recherche globale, les archives, les
-- statistiques et l'historique — doit fonctionner sur l'intégralité des
-- données, plusieurs années et plusieurs milliers de rendez-vous.
-- Non destructif : aucune table/colonne existante modifiée en profondeur,
-- uniquement extension + index + fonctions nouvelles.
-- ============================================================

create extension if not exists pg_trgm;

-- Index trigram pour une recherche ILIKE rapide à grande échelle (jamais un
-- full scan de la table à chaque frappe).
create index if not exists idx_bookings_guest_name_trgm on bookings using gin (guest_name gin_trgm_ops);
create index if not exists idx_bookings_guest_phone_trgm on bookings using gin (guest_phone gin_trgm_ops);
create index if not exists idx_bookings_guest_email_trgm on bookings using gin (guest_email gin_trgm_ops);
create index if not exists idx_bookings_guest_address_trgm on bookings using gin (guest_address gin_trgm_ops);
create index if not exists idx_bookings_reference_trgm on bookings using gin (reference gin_trgm_ops);
create index if not exists idx_customer_profiles_first_name_trgm on customer_profiles using gin (first_name gin_trgm_ops);
create index if not exists idx_customer_profiles_last_name_trgm on customer_profiles using gin (last_name gin_trgm_ops);
create index if not exists idx_customer_profiles_phone_trgm on customer_profiles using gin (phone gin_trgm_ops);
create index if not exists idx_customer_equipment_brand_trgm on customer_equipment using gin (brand gin_trgm_ops);
create index if not exists idx_customer_equipment_model_trgm on customer_equipment using gin (model gin_trgm_ops);
create index if not exists idx_profiles_email_trgm on profiles using gin (email gin_trgm_ops);

-- Index supplémentaires pour le tri/filtre à grande échelle des onglets
-- Terminées/Annulées-Refusées (pagination serveur, jamais tout le tableau
-- téléchargé pour filtrer ensuite en JavaScript).
create index if not exists idx_bookings_status_date on bookings(status, date desc);
create index if not exists idx_bookings_cancellation_type on bookings(cancellation_type) where cancellation_type is not null;
create index if not exists idx_bookings_customer_user_id on bookings(customer_user_id);

-- ------------------------------------------------------------
-- Recherche globale server-side (section 14/24) : interroge directement
-- bookings + customer_profiles + profiles + customer_equipment +
-- professional_accounts, jamais limitée aux 500 dernières réservations
-- chargées côté client. Retourne, pour chaque réservation correspondante,
-- assez d'informations pour l'afficher dans la liste de résultats et
-- ouvrir soit la fiche rendez-vous, soit la fiche client complète.
-- ------------------------------------------------------------
create or replace function admin_search_bookings(p_query text, p_limit int default 30)
returns table (
  booking_id uuid, reference text, date date, start_time time, status text,
  customer_user_id uuid, guest_name text, guest_phone text, guest_email text,
  contact_name text, contact_phone text, contact_email text,
  equipment_brand text, equipment_model text, service_name text
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_needle text := '%' || trim(p_query) || '%';
begin
  if not is_admin() then
    raise exception 'Accès réservé à l''administration.';
  end if;
  if trim(p_query) = '' then
    return;
  end if;

  return query
  select distinct on (b.id)
    b.id, b.reference, b.date, b.start_time, b.status,
    b.customer_user_id, b.guest_name, b.guest_phone, b.guest_email,
    coalesce(cp.first_name || ' ' || cp.last_name, pa.legal_name, b.guest_name, 'Client') as contact_name,
    coalesce(cp.phone, pa.phone, b.guest_phone) as contact_phone,
    coalesce(prof.email, b.guest_email) as contact_email,
    ce.brand, ce.model,
    sv.name
  from bookings b
  left join customer_profiles cp on cp.user_id = b.customer_user_id
  left join profiles prof on prof.user_id = b.customer_user_id
  left join professional_accounts pa on pa.id = b.professional_account_id
  left join customer_equipment ce on ce.id = b.equipment_id
  left join services sv on sv.id = b.service_id
  where
    b.guest_name ilike v_needle or b.guest_phone ilike v_needle or b.guest_email ilike v_needle
    or b.guest_address ilike v_needle or b.reference ilike v_needle
    or cp.first_name ilike v_needle or cp.last_name ilike v_needle or cp.phone ilike v_needle
    or prof.email ilike v_needle
    or pa.legal_name ilike v_needle or pa.phone ilike v_needle
    or ce.brand ilike v_needle or ce.model ilike v_needle
  order by b.id, b.date desc
  limit p_limit;
end;
$$;

revoke all on function admin_search_bookings(text, int) from public;
grant execute on function admin_search_bookings(text, int) to authenticated;

-- ------------------------------------------------------------
-- Statistiques server-side (section "Statistiques", période quelconque) :
-- comptages calculés en base sur la période demandée, jamais sur un sous-
-- ensemble chargé côté client. Les catégories ne sont jamais additionnées
-- naïvement : chaque compteur est une requête indépendante sur son propre
-- critère.
-- ------------------------------------------------------------
create or replace function admin_booking_stats(p_start date, p_end date)
returns table (
  requests_received bigint, confirmed bigint, completed bigint,
  cancelled_client bigint, cancelled_admin bigint, refused bigint, no_show bigint,
  revenue_cents bigint, revenue_countable bigint
)
language plpgsql
security definer
set search_path = public
as $$
begin
  if not is_admin() then
    raise exception 'Accès réservé à l''administration.';
  end if;

  return query
  select
    (select count(*) from bookings where created_at::date >= p_start and created_at::date <= p_end) as requests_received,
    (select count(*) from bookings where status in ('CONFIRMED','IN_PROGRESS','COMPLETED') and date >= p_start and date <= p_end) as confirmed,
    (select count(*) from bookings where status = 'COMPLETED' and date >= p_start and date <= p_end) as completed,
    (select count(*) from bookings where cancellation_type = 'cancelled_client' and cancelled_at::date >= p_start and cancelled_at::date <= p_end) as cancelled_client,
    (select count(*) from bookings where cancellation_type = 'cancelled_admin' and cancelled_at::date >= p_start and cancelled_at::date <= p_end) as cancelled_admin,
    (select count(*) from bookings where cancellation_type = 'refused' and cancelled_at::date >= p_start and cancelled_at::date <= p_end) as refused,
    (select count(*) from bookings where status = 'NO_SHOW' and date >= p_start and date <= p_end) as no_show,
    (select coalesce(sum(total_cents), 0) from bookings where status = 'COMPLETED' and date >= p_start and date <= p_end and total_cents is not null) as revenue_cents,
    (select count(*) from bookings where status = 'COMPLETED' and date >= p_start and date <= p_end and total_cents is not null) as revenue_countable;
end;
$$;

revoke all on function admin_booking_stats(date, date) from public;
grant execute on function admin_booking_stats(date, date) to authenticated;

-- ------------------------------------------------------------
-- Historique de statut d'un rendez-vous (section 20 UI) : lecture directe
-- de booking_status_history (déjà créée en 0054, déjà alimentée par
-- trigger), exposée ici en RPC pour un tri explicite ancien->récent avec
-- jointure sur le profil de l'auteur quand connu.
-- ------------------------------------------------------------
create or replace function admin_booking_status_history(p_booking_id uuid)
returns table (
  old_status text, new_status text, changed_at timestamptz, reason text, changed_by_email text
)
language plpgsql
security definer
set search_path = public
as $$
begin
  if not is_admin() then
    raise exception 'Accès réservé à l''administration.';
  end if;
  return query
  select h.old_status, h.new_status, h.changed_at, h.reason, prof.email
  from booking_status_history h
  left join profiles prof on prof.user_id = h.changed_by
  where h.booking_id = p_booking_id
  order by h.changed_at asc;
end;
$$;

revoke all on function admin_booking_status_history(uuid) from public;
grant execute on function admin_booking_status_history(uuid) to authenticated;
