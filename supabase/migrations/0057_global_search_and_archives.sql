-- ============================================================
-- Recherche globale catégorisée (section 5) + recherche Archives sur
-- l'intégralité de l'historique (correction de la limite au mois chargé,
-- section 1). Les deux s'appuient sur les mêmes index trigram déjà posés
-- en 0055, plus la table clients de 0056 pour une identité unique.
-- ============================================================

-- ------------------------------------------------------------
-- Recherche Archives : TOUTES les interventions FINALIZED, toutes
-- années/mois confondus, filtrée côté serveur (jamais le mois actuellement
-- chargé côté client). Pagination par offset/limite pour rester rapide
-- avec plusieurs dizaines de milliers de lignes.
-- ------------------------------------------------------------
create or replace function admin_search_archives(p_query text, p_limit int default 50, p_offset int default 0)
returns table (
  intervention_id uuid, booking_id uuid, ended_at timestamptz, report_number text,
  reference text, contact_name text, service_name text, total_cents int
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

  return query
  select distinct on (iv.id)
    iv.id, b.id, iv.ended_at, iv.report_number, b.reference,
    coalesce(cl.first_name || ' ' || cl.last_name, b.guest_name, 'Client') as contact_name,
    sv.name, b.total_cents
  from interventions iv
  join bookings b on b.id = iv.booking_id
  left join clients cl on cl.id = b.client_id
  left join services sv on sv.id = b.service_id
  where iv.report_status = 'FINALIZED'
    and (
      trim(p_query) = ''
      or b.guest_name ilike v_needle or b.guest_phone ilike v_needle or b.guest_email ilike v_needle
      or b.guest_address ilike v_needle or b.reference ilike v_needle or iv.report_number ilike v_needle
      or cl.first_name ilike v_needle or cl.last_name ilike v_needle or cl.phone ilike v_needle or cl.email ilike v_needle
    )
  order by iv.id, iv.ended_at desc
  limit p_limit offset p_offset;
end;
$$;

revoke all on function admin_search_archives(text, int, int) from public;
grant execute on function admin_search_archives(text, int, int) to authenticated;

-- ------------------------------------------------------------
-- Recherche globale catégorisée (section 5) : clients / interventions /
-- équipements / devis / factures / contrats, en une seule requête
-- multi-UNION, chaque ligne portant sa propre catégorie pour un
-- regroupement côté frontend.
-- ------------------------------------------------------------
create or replace function admin_global_search(p_query text, p_limit_per_category int default 8)
returns table (category text, item_id uuid, title text, subtitle text, item_date date)
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
  if trim(p_query) = '' then return; end if;

  return query
  (
    select 'client', c.id,
      coalesce(c.first_name || ' ' || c.last_name, 'Client'),
      coalesce(c.phone, c.email, ''),
      c.created_at::date
    from clients c
    where c.merged_into is null and (
      c.first_name ilike v_needle or c.last_name ilike v_needle or c.email ilike v_needle
      or c.phone ilike v_needle or c.address ilike v_needle
    )
    limit p_limit_per_category
  )
  union all
  (
    select 'intervention', iv.id,
      coalesce(sv.name, 'Intervention') || ' — ' || coalesce(cl.first_name || ' ' || cl.last_name, b.guest_name, 'Client'),
      coalesce(iv.report_number, b.reference, ''),
      iv.ended_at::date
    from interventions iv
    join bookings b on b.id = iv.booking_id
    left join clients cl on cl.id = b.client_id
    left join services sv on sv.id = b.service_id
    where b.reference ilike v_needle or iv.report_number ilike v_needle
      or b.guest_name ilike v_needle or cl.first_name ilike v_needle or cl.last_name ilike v_needle
    limit p_limit_per_category
  )
  union all
  (
    select 'equipment', ce.id,
      coalesce(ce.brand, '') || ' ' || coalesce(ce.model, ''),
      coalesce(cl.first_name || ' ' || cl.last_name, ''),
      ce.created_at::date
    from customer_equipment ce
    left join clients cl on cl.id = ce.client_id
    where ce.brand ilike v_needle or ce.model ilike v_needle or ce.serial_number ilike v_needle or ce.reference ilike v_needle
    limit p_limit_per_category
  )
  union all
  (
    select 'quote', q.id, coalesce(q.title, 'Devis ' || q.reference), q.reference, q.created_at::date
    from quotes q
    where q.reference ilike v_needle or q.title ilike v_needle
    limit p_limit_per_category
  )
  union all
  (
    select 'invoice', i.id, 'Facture ' || i.reference, i.reference, i.created_at::date
    from invoices i
    where i.reference ilike v_needle
    limit p_limit_per_category
  )
  union all
  (
    select 'contract', sc.id,
      'Contrat ' || coalesce(sc.contract_type, '') || ' — ' || coalesce(cl.first_name || ' ' || cl.last_name, ''),
      sc.energy_type, sc.start_date
    from service_contracts sc
    left join clients cl on cl.id = sc.client_id
    where cl.first_name ilike v_needle or cl.last_name ilike v_needle
    limit p_limit_per_category
  );
end;
$$;

revoke all on function admin_global_search(text, int) from public;
grant execute on function admin_global_search(text, int) to authenticated;

create index if not exists idx_customer_equipment_serial_trgm on customer_equipment using gin (serial_number gin_trgm_ops);
create index if not exists idx_customer_equipment_reference_trgm on customer_equipment using gin (reference gin_trgm_ops);
create index if not exists idx_quotes_reference_trgm on quotes using gin (reference gin_trgm_ops);
create index if not exists idx_invoices_reference_trgm on invoices using gin (reference gin_trgm_ops);
create index if not exists idx_interventions_report_number_trgm on interventions using gin (report_number gin_trgm_ops);
