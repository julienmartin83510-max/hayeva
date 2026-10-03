-- ============================================================
-- admin_search_bookings renvoie désormais client_id (table clients,
-- 0056_client_360.sql) en plus de customer_user_id, et résout le nom/
-- téléphone/e-mail de contact en priorité via la fiche client centrale —
-- nécessaire pour que "Voir client" depuis un résultat de recherche
-- fonctionne aussi pour un client invité (sans compte), qui n'avait
-- jusqu'ici aucune fiche persistante. Signature de retour modifiée :
-- DROP + CREATE requis par Postgres (impossible de changer les colonnes
-- de retour d'une fonction existante par CREATE OR REPLACE).
-- ============================================================

drop function if exists admin_search_bookings(text, int);

create function admin_search_bookings(p_query text, p_limit int default 30)
returns table (
  booking_id uuid, reference text, date date, start_time time, status text,
  customer_user_id uuid, client_id uuid, guest_name text, guest_phone text, guest_email text,
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
    b.customer_user_id, b.client_id, b.guest_name, b.guest_phone, b.guest_email,
    coalesce(cl.first_name || ' ' || cl.last_name, cp.first_name || ' ' || cp.last_name, pa.legal_name, b.guest_name, 'Client') as contact_name,
    coalesce(cl.phone, cp.phone, pa.phone, b.guest_phone) as contact_phone,
    coalesce(cl.email, prof.email, b.guest_email) as contact_email,
    ce.brand, ce.model,
    sv.name
  from bookings b
  left join clients cl on cl.id = b.client_id
  left join customer_profiles cp on cp.user_id = b.customer_user_id
  left join profiles prof on prof.user_id = b.customer_user_id
  left join professional_accounts pa on pa.id = b.professional_account_id
  left join customer_equipment ce on ce.id = b.equipment_id
  left join services sv on sv.id = b.service_id
  where
    b.guest_name ilike v_needle or b.guest_phone ilike v_needle or b.guest_email ilike v_needle
    or b.guest_address ilike v_needle or b.reference ilike v_needle
    or cl.first_name ilike v_needle or cl.last_name ilike v_needle or cl.phone ilike v_needle or cl.email ilike v_needle
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
