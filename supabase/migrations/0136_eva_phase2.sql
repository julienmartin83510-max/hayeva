-- EVA — phase 2 : assistante centrale (lectures étendues + actions confirmées).
--
-- S'appuie sur 0135 (eva_run, propositions, journal, garde _eva_guard).
-- Lectures : eva_query (même garde et même journal que eva_run).
-- Actions : nouvelles propositions branchées sur les points d'extension de
-- 0135 (_eva_ext_agent / _eva_prepare_ext / _eva_execute_ext). Rien n'est
-- écrit sans proposition confirmée par un bouton ; l'exécution reprend les
-- mêmes écritures que les écrans existants de l'administration (mêmes
-- déclencheurs : e-mails, Apple Calendar, numérotation, historique).
-- Aucune donnée existante n'est modifiée ou supprimée par cette migration.

-- =====================================================================
-- 1) Lectures
-- =====================================================================
create or replace function public._eva_booking_brief(b bookings)
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object('booking_id', b.id, 'reference', b.reference, 'date', b.date, 'start', _eva_hhmm(_eva_min(b.start_time)),
    'end', _eva_hhmm(_eva_min(b.start_time) + coalesce(b.service_duration_minutes, 60)), 'status', b.status,
    'service', coalesce((select name from service_packs where id = b.service_pack_id), (select name from services where id = b.service_id), 'Intervention'),
    'client', _eva_client_name(b.client_id, b.customer_user_id, b.guest_name), 'client_id', b.client_id, 'total_cents', b.total_cents)
$$;

-- Plusieurs jours : nombre et liste des rendez-vous actifs.
create or replace function public._eva_agenda_range(p_from date, p_to date)
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if p_to < p_from or p_to - p_from > 62 then raise exception 'PERIODE_INVALIDE'; end if;
  return jsonb_build_object('from', p_from, 'to', p_to,
    'count', (select count(*) from bookings where date between p_from and p_to and status in ('PENDING', 'CONFIRMED', 'IN_PROGRESS', 'COMPLETED')),
    'by_status', coalesce((select jsonb_object_agg(status, n) from (select status, count(*) n from bookings where date between p_from and p_to group by status) s), '{}'::jsonb),
    'days', coalesce((select jsonb_agg(jsonb_build_object('date', d, 'items', items) order by d) from (
        select b.date d, jsonb_agg(_eva_booking_brief(b) order by b.start_time) items
          from bookings b where b.date between p_from and p_to and b.status in ('PENDING', 'CONFIRMED', 'IN_PROGRESS', 'COMPLETED')
         group by b.date) x), '[]'::jsonb));
end $$;

-- Statistiques de réservation : fonction existante admin_booking_stats.
create or replace function public._eva_stats(p_from date, p_to date)
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce((select to_jsonb(s) from admin_booking_stats(p_from, p_to) s limit 1), '{}'::jsonb) || jsonb_build_object('from', p_from, 'to', p_to)
$$;

-- Catalogue et tarifs (prix enregistrés uniquement).
create or replace function public._eva_catalog(p_query text, p_include_hidden boolean)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_words text[] := array(select w from unnest(regexp_split_to_array(_eva_norm(coalesce(p_query, '')), '[^a-z0-9]+')) w
                               where char_length(w) >= 3 and w not in ('tarif', 'tarifs', 'prix', 'prestation', 'prestations', 'catalogue', 'combien', 'coute', 'cout', 'les', 'des', 'pour', 'une'));
begin
  return jsonb_build_object('query', p_query, 'items', coalesce((select jsonb_agg(x order by x ->> 'category', x ->> 'label') from (
    select jsonb_build_object('kind', k.kind, 'id', k.id, 'label', k.label, 'category', k.category, 'mode', k.mode,
             'price_cents', k.price, 'duration_minutes', k.dur, 'active', k.active) x
      from (select 'service' kind, s.id, s.name label, s.category, coalesce(s.price_display_mode, 'FIXED') mode, s.base_price_cents price, s.duration_minutes dur, s.is_active active from services s
            union all
            select 'pack', p.id, s.name || ' — ' || p.name, s.category, 'FIXED', p.price_cents, p.duration_minutes, (p.is_active and s.is_active) from service_packs p join services s on s.id = p.service_id) k
     where (k.active or coalesce(p_include_hidden, false))
       and (cardinality(v_words) = 0 or not exists (select 1 from unnest(v_words) w where position(w in _eva_norm(k.label || ' ' || k.category)) = 0))
     limit 60) z), '[]'::jsonb));
end $$;

-- Factures et paiements (filtres facultatifs).
create or replace function public._eva_invoices_list(p_client uuid, p_status text, p_from date, p_to date)
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'invoices', coalesce((select jsonb_agg(jsonb_build_object('invoice_id', i.id, 'reference', i.reference, 'status', i.status, 'total_cents', i.total_cents,
                 'paid_cents', coalesce((select sum(amount_cents) from invoice_payments p where p.invoice_id = i.id), 0),
                 'issued_at', i.issued_at, 'due_date', i.due_date, 'client', _eva_client_name(i.client_id, i.customer_user_id, null)) order by coalesce(i.issued_at, i.created_at) desc)
               from (select * from invoices i
                      where (p_client is null or i.client_id = p_client)
                        and (p_status is null or i.status = p_status)
                        and (p_from is null or (coalesce(i.issued_at, i.created_at) at time zone 'Europe/Paris')::date >= p_from)
                        and (p_to is null or (coalesce(i.issued_at, i.created_at) at time zone 'Europe/Paris')::date <= p_to)
                      order by coalesce(i.issued_at, i.created_at) desc limit 40) i), '[]'::jsonb),
    'payments', coalesce((select jsonb_agg(jsonb_build_object('amount_cents', p.amount_cents, 'method', p.method, 'paid_on', p.paid_on, 'invoice', i.reference,
                 'client', _eva_client_name(i.client_id, i.customer_user_id, null)) order by p.paid_on desc)
               from (select * from invoice_payments order by paid_on desc limit 200) p join invoices i on i.id = p.invoice_id
              where (p_client is null or i.client_id = p_client)
                and (p_from is null or p.paid_on >= p_from) and (p_to is null or p.paid_on <= p_to)), '[]'::jsonb))
$$;

-- Fiche complète d'un client : coordonnées, rendez-vous, interventions,
-- équipements (prochain entretien), devis, factures, fidélité, parrainage.
create or replace function public._eva_client_detail(p_client uuid)
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'client', jsonb_build_object('client_id', c.id, 'name', trim(coalesce(c.first_name, '') || ' ' || coalesce(c.last_name, '')), 'first_name', c.first_name, 'last_name', c.last_name,
       'phone', c.phone, 'email', c.email, 'address', c.address, 'postal_code', c.postal_code, 'city', c.city, 'type', c.client_type, 'notes', c.notes,
       'has_account', c.user_id is not null, 'since', c.created_at),
    'bookings', coalesce((select jsonb_agg(_eva_booking_brief(b) order by b.date desc, b.start_time desc) from (select * from bookings b where b.client_id = c.id order by date desc, start_time desc limit 12) b), '[]'::jsonb),
    'interventions', coalesce((select jsonb_agg(jsonb_build_object('intervention_id', i.id, 'date', coalesce(i.performed_at, i.started_at, i.created_at), 'booking', b.reference,
         'service', coalesce((select name from services where id = b.service_id), 'Intervention'), 'report_status', i.report_status, 'report_number', i.report_number,
         'completion', i.completion_status, 'observations', left(i.observations, 300), 'recommendations', left(i.recommendations, 300),
         'equipment', (select coalesce(nullif(trim(coalesce(e.brand, '') || ' ' || coalesce(e.model, '')), ''), e.equipment_type) from customer_equipment e where e.id = i.equipment_id))
         order by coalesce(i.performed_at, i.started_at, i.created_at) desc)
       from interventions i join bookings b on b.id = i.booking_id where b.client_id = c.id), '[]'::jsonb),
    'equipment', coalesce((select jsonb_agg(jsonb_build_object('equipment_id', e.id, 'type', e.equipment_type, 'brand', e.brand, 'model', e.model, 'location', e.location,
         'last_service', e.last_service_at, 'next_due', equipment_next_maintenance_due(e), 'reminders', e.maintenance_reminders_enabled) order by e.created_at)
       from customer_equipment e where e.client_id = c.id), '[]'::jsonb),
    'quotes', coalesce((select jsonb_agg(jsonb_build_object('quote_id', q.id, 'reference', q.reference, 'title', q.title, 'status', q.status, 'total_cents', q.total_cents, 'created_at', q.created_at) order by q.created_at desc)
       from quotes q where q.client_id = c.id or (c.user_id is not null and q.customer_user_id = c.user_id)), '[]'::jsonb),
    'invoices', coalesce((select jsonb_agg(jsonb_build_object('invoice_id', i.id, 'reference', i.reference, 'status', i.status, 'total_cents', i.total_cents) order by i.created_at desc)
       from invoices i where i.client_id = c.id), '[]'::jsonb),
    'wallet_cents', coalesce((select balance_cents from wallet_balances w where w.client_id = c.id), 0),
    'referral', (select jsonb_build_object('code', rc.code, 'status', rc.status, 'type', rc.participant_type) from referral_codes rc where rc.client_id = c.id))
  from clients c where c.id = p_client and c.merged_into is null
$$;

-- Équipements dont l'entretien arrive à échéance (ou est dépassé).
create or replace function public._eva_maintenance_due(p_days int)
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object('days', p_days, 'items', coalesce((select jsonb_agg(x order by x ->> 'next_due') from (
    select jsonb_build_object('client_id', c.id, 'client', trim(coalesce(c.first_name, '') || ' ' || coalesce(c.last_name, '')), 'phone', c.phone, 'city', c.city,
             'equipment', coalesce(nullif(trim(coalesce(e.brand, '') || ' ' || coalesce(e.model, '')), ''), e.equipment_type), 'type', e.equipment_type,
             'last_service', e.last_service_at, 'next_due', equipment_next_maintenance_due(e),
             'overdue', equipment_next_maintenance_due(e) < current_date,
             'next_booking', (select min(b.date) from bookings b where b.client_id = c.id and b.date >= current_date and b.status in ('PENDING', 'CONFIRMED'))) x
      from customer_equipment e join clients c on c.id = e.client_id and c.merged_into is null
     where equipment_next_maintenance_due(e) is not null
       and equipment_next_maintenance_due(e) <= current_date + greatest(0, least(coalesce(p_days, 60), 365))
       and equipment_next_maintenance_due(e) >= current_date - 365
     limit 80) z), '[]'::jsonb))
$$;

-- Parrainage (fonction existante admin_list_referrers) et fidélité.
create or replace function public._eva_referrals(p_query text)
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object('query', p_query, 'referrers', coalesce((select jsonb_agg(jsonb_build_object('client_id', r ->> 'client_id', 'name', r ->> 'name', 'code', r ->> 'code',
           'status', r ->> 'status', 'uses', (r ->> 'uses_count')::int, 'clients', coalesce((r ->> 'clients_count')::int, (r ->> 'converted_count')::int)))
         from jsonb_array_elements(coalesce(admin_list_referrers(nullif(trim(coalesce(p_query, '')), ''), 'all'), '[]'::jsonb)) r), '[]'::jsonb))
$$;
create or replace function public._eva_loyalty(p_client uuid)
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object('client_id', p_client,
    'balance_cents', coalesce((select balance_cents from wallet_balances where client_id = p_client), 0),
    'transactions', coalesce((select jsonb_agg(jsonb_build_object('at', t.created_at, 'type', t.type, 'amount_cents', t.amount_cents, 'reason', t.reason) order by t.created_at desc)
       from (select * from wallet_transactions where client_id = p_client order by created_at desc limit 15) t), '[]'::jsonb))
$$;

-- Compte rendu d'intervention d'un rendez-vous.
create or replace function public._eva_report(p_booking uuid)
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object('booking', _eva_booking_brief(b),
    'intervention', (select jsonb_build_object('intervention_id', i.id, 'report_status', i.report_status, 'report_number', i.report_number,
        'observations', i.observations, 'recommendations', i.recommendations, 'completion', i.completion_status, 'auto_summary', i.auto_summary,
        'signed', i.client_signed_at is not null)
      from interventions i where i.booking_id = b.id order by i.created_at desc limit 1))
  from bookings b where b.id = p_booking
$$;

-- Résolution d'un client par texte ou identifiant (utilisé par eva_query).
create or replace function public._eva_resolve_client(a jsonb)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v jsonb;
begin
  if nullif(a ->> 'client_id', '') is not null then
    return jsonb_build_object('client_id', a ->> 'client_id', 'clients', (select jsonb_agg(jsonb_build_object('client_id', c.id, 'name', trim(coalesce(c.first_name, '') || ' ' || coalesce(c.last_name, '')), 'city', c.city))
                                                                          from clients c where c.id = (a ->> 'client_id')::uuid));
  end if;
  v := _eva_find_client(coalesce(a ->> 'client', a ->> 'query')) -> 'clients';
  return jsonb_build_object('client_id', case when jsonb_array_length(v) = 1 then v -> 0 ->> 'client_id' end, 'clients', v);
end $$;

-- Point d'entrée des lectures de phase 2 (même garde et même journal que eva_run).
create or replace function public.eva_query(p_intent text, p_args jsonb default '{}'::jsonb, p_command text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  a jsonb := coalesce(p_args, '{}'::jsonb); v_agent text; v_data jsonb; v_empty boolean := false; r jsonb; v_id uuid;
  v_today date := (now() at time zone 'Europe/Paris')::date; v_from date; v_to date;
begin
  v_agent := case p_intent when 'agenda_range' then 'planning' when 'stats' then 'planning' when 'catalog' then 'devis'
    when 'invoices_list' then 'factures' when 'client_detail' then null when 'maintenance_due' then 'planning'
    when 'referrals' then null when 'loyalty' then null when 'report' then 'planning' else 'inconnu' end;
  if v_agent = 'inconnu' then raise exception 'INTENTION_INCONNUE'; end if;
  perform _eva_guard(v_agent);
  begin
    v_from := coalesce(nullif(a ->> 'from', '')::date, v_today);
    v_to := coalesce(nullif(a ->> 'to', '')::date, v_from + 6);
  exception when others then raise exception 'DATE_INVALIDE';
  end;
  if p_intent = 'agenda_range' then
    v_data := _eva_agenda_range(v_from, v_to); v_empty := (v_data ->> 'count')::int = 0;
  elsif p_intent = 'stats' then
    if v_to < v_from or v_to - v_from > 400 then raise exception 'PERIODE_INVALIDE'; end if;
    v_data := _eva_stats(v_from, v_to);
  elsif p_intent = 'catalog' then
    v_data := _eva_catalog(a ->> 'query', coalesce((a ->> 'include_hidden')::boolean, false)); v_empty := jsonb_array_length(v_data -> 'items') = 0;
  elsif p_intent = 'invoices_list' then
    r := case when coalesce(a ->> 'client', a ->> 'client_id') is not null then _eva_resolve_client(a) end;
    if r is not null and r ->> 'client_id' is null then
      v_data := jsonb_build_object('clients', r -> 'clients', 'invoices', '[]'::jsonb, 'payments', '[]'::jsonb); v_empty := true;
    else
      v_data := _eva_invoices_list((r ->> 'client_id')::uuid, nullif(a ->> 'status', ''), nullif(a ->> 'from', '')::date, nullif(a ->> 'to', '')::date)
                || jsonb_build_object('clients', coalesce(r -> 'clients', '[]'::jsonb));
      v_empty := jsonb_array_length(v_data -> 'invoices') + jsonb_array_length(v_data -> 'payments') = 0;
    end if;
  elsif p_intent in ('client_detail', 'loyalty') then
    r := _eva_resolve_client(a);
    if r ->> 'client_id' is null then
      v_data := jsonb_build_object('clients', r -> 'clients'); v_empty := jsonb_array_length(coalesce(r -> 'clients', '[]'::jsonb)) = 0;
    else
      v_id := (r ->> 'client_id')::uuid;
      v_data := case when p_intent = 'loyalty' then _eva_loyalty(v_id) || jsonb_build_object('clients', r -> 'clients') else _eva_client_detail(v_id) end;
      if v_data is null then raise exception 'Client introuvable.'; end if;
    end if;
  elsif p_intent = 'maintenance_due' then
    v_data := _eva_maintenance_due(coalesce(nullif(a ->> 'days', '')::int, 60)); v_empty := jsonb_array_length(v_data -> 'items') = 0;
  elsif p_intent = 'referrals' then
    v_data := _eva_referrals(a ->> 'query'); v_empty := jsonb_array_length(v_data -> 'referrers') = 0;
  elsif p_intent = 'report' then
    v_data := _eva_report((a ->> 'booking_id')::uuid); if v_data is null then raise exception 'Rendez-vous introuvable.'; end if;
  end if;
  perform _eva_log(p_command, p_intent, v_agent, case when v_empty then 'empty' else 'ok' end, jsonb_build_object('args', a));
  return jsonb_build_object('ok', true, 'intent', p_intent, 'agent', v_agent, 'empty', v_empty, 'data', v_data, 'generated_at', now());
end $$;

-- =====================================================================
-- 2) Actions (propositions confirmées)
-- =====================================================================
alter table public.eva_proposals drop constraint if exists eva_proposals_kind_check;
alter table public.eva_proposals add constraint eva_proposals_kind_check check (kind in (
  'quote_draft', 'invoice_draft', 'reschedule', 'booking_confirm', 'invoice_issue', 'invoice_payment',
  'client_create', 'client_update', 'booking_create', 'booking_cancel', 'service_create', 'service_publish',
  'quote_update', 'quote_send', 'report_notes', 'referrer_status', 'referrer_code', 'wallet_adjust'));

create or replace function public._eva_ext_agent(p_kind text)
returns text language sql immutable as $$
  select case p_kind
    when 'client_create' then 'clients' when 'client_update' then 'clients'
    when 'booking_create' then 'planning' when 'booking_cancel' then 'planning' when 'report_notes' then 'planning'
    when 'service_create' then 'devis' when 'service_publish' then 'devis' when 'quote_update' then 'devis' when 'quote_send' then 'devis'
    when 'referrer_status' then 'fidelite' when 'referrer_code' then 'fidelite' when 'wallet_adjust' then 'fidelite' end
$$;

-- Agents de la phase 2 activables comme les autres.
update public.eva_settings set agents = '{"clients": true, "fidelite": true}'::jsonb || agents where id = 1;

create or replace function public.eva_set_settings(p_enabled boolean, p_agents jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null or not is_admin() then raise exception 'EVA est réservée à l''administrateur.' using errcode = '42501'; end if;
  if p_agents is null or jsonb_typeof(p_agents) <> 'object'
     or exists (select 1 from jsonb_object_keys(p_agents) k where k not in ('planning', 'devis', 'factures', 'clients', 'fidelite'))
     or exists (select 1 from jsonb_each(p_agents) e where jsonb_typeof(e.value) <> 'boolean') then raise exception 'Réglage des agents invalide.'; end if;
  update eva_settings set enabled = coalesce(p_enabled, enabled), agents = agents || p_agents, updated_at = now(), updated_by = auth.uid() where id = 1;
  perform _eva_log(null, 'settings', null, 'settings', jsonb_build_object('enabled', p_enabled, 'agents', p_agents));
  return jsonb_build_object('ok', true);
end $$;
revoke all on function public.eva_set_settings(boolean, jsonb) from public, anon;
grant execute on function public.eva_set_settings(boolean, jsonb) to authenticated;

create or replace function public._eva_clean(p text, p_max int) returns text language sql immutable as $$
  select nullif(left(regexp_replace(trim(coalesce(p, '')), '\s+', ' ', 'g'), p_max), '')
$$;

create or replace function public._eva_prepare_ext(p_kind text, p jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  c clients; b bookings; q quotes; s services; o quote_options; v_name text; v_cons text[] := '{}'; v_payload jsonb; v_entity text; v_title text; v_level int := 3;
  v_dup text; v_changes jsonb := '{}'::jsonb; k text; v_old text; v_new text; v_dur int; v_price int; v_start int; v_label text; v_svc uuid; v_pack uuid; v_slug text;
  v_fields text[] := array['first_name', 'last_name', 'phone', 'email', 'address', 'postal_code', 'city', 'client_type', 'notes'];
  v_labels jsonb := '{"first_name":"Prénom","last_name":"Nom","phone":"Téléphone","email":"E-mail","address":"Adresse","postal_code":"Code postal","city":"Ville","client_type":"Type","notes":"Notes"}';
begin
  -- ----------------------------------------------------------- clients
  if p_kind = 'client_create' then
    v_level := 2;
    v_payload := jsonb_build_object(
      'first_name', _eva_clean(p ->> 'first_name', 80), 'last_name', _eva_clean(p ->> 'last_name', 80),
      'phone', _eva_clean(regexp_replace(coalesce(p ->> 'phone', ''), '[^0-9+]', '', 'g'), 20), 'email', lower(_eva_clean(p ->> 'email', 160)),
      'address', _eva_clean(p ->> 'address', 200), 'postal_code', _eva_clean(p ->> 'postal_code', 10), 'city', _eva_clean(p ->> 'city', 80),
      'client_type', coalesce(nullif(p ->> 'client_type', ''), 'particulier'), 'notes', _eva_clean(p ->> 'notes', 500));
    if v_payload ->> 'first_name' is null and v_payload ->> 'last_name' is null then raise exception 'Indiquez au moins un nom.'; end if;
    if v_payload ->> 'phone' is null and v_payload ->> 'email' is null then raise exception 'Indiquez un téléphone ou un e-mail.'; end if;
    if v_payload ->> 'email' is not null and v_payload ->> 'email' !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'E-mail invalide.'; end if;
    if v_payload ->> 'phone' is not null and char_length(regexp_replace(v_payload ->> 'phone', '\D', '', 'g')) < 9 then raise exception 'Téléphone invalide.'; end if;
    if v_payload ->> 'client_type' not in ('particulier', 'professionnel') then raise exception 'Type de client invalide.'; end if;
    select trim(coalesce(first_name, '') || ' ' || coalesce(last_name, '')) into v_dup from clients
     where merged_into is null and ((v_payload ->> 'email' is not null and lower(email) = v_payload ->> 'email')
        or (v_payload ->> 'phone' is not null and regexp_replace(coalesce(phone, ''), '\D', '', 'g') = regexp_replace(v_payload ->> 'phone', '\D', '', 'g'))) limit 1;
    if v_dup is not null then raise exception 'DOUBLON : un client existe déjà avec ce téléphone ou cet e-mail (%).', v_dup; end if;
    v_name := trim(coalesce(v_payload ->> 'first_name', '') || ' ' || coalesce(v_payload ->> 'last_name', ''));
    v_entity := 'new-client:' || lower(coalesce(v_payload ->> 'email', v_payload ->> 'phone'));
    v_title := 'Créer la fiche client ' || v_name;
    v_cons := array['Nouvelle fiche : ' || v_name || coalesce(' · ' || (v_payload ->> 'phone'), '') || coalesce(' · ' || (v_payload ->> 'email'), '') ||
                    coalesce(' · ' || (v_payload ->> 'city'), '') || '.', 'Aucun message n''est envoyé au client.'];

  elsif p_kind = 'client_update' then
    select * into c from clients where id = (p ->> 'client_id')::uuid and merged_into is null;
    if not found then raise exception 'Client introuvable.'; end if;
    for k in select jsonb_object_keys(coalesce(p -> 'changes', '{}'::jsonb)) loop
      if not (k = any(v_fields)) then raise exception 'Champ non modifiable : %.', k; end if;
      v_new := case when k = 'email' then lower(_eva_clean(p -> 'changes' ->> k, 160)) when k = 'phone' then _eva_clean(regexp_replace(coalesce(p -> 'changes' ->> k, ''), '[^0-9+]', '', 'g'), 20)
                    else _eva_clean(p -> 'changes' ->> k, case when k = 'notes' then 500 else 200 end) end;
      execute format('select ($1).%I::text', k) into v_old using c;
      if v_new is distinct from v_old then
        if k = 'email' and v_new is not null and v_new !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'E-mail invalide.'; end if;
        if k = 'client_type' and v_new not in ('particulier', 'professionnel') then raise exception 'Type de client invalide.'; end if;
        v_changes := v_changes || jsonb_build_object(k, v_new);
        v_cons := v_cons || ((v_labels ->> k) || ' : « ' || coalesce(v_old, '—') || ' » → « ' || coalesce(v_new, '—') || ' »');
      end if;
    end loop;
    if v_changes = '{}'::jsonb then raise exception 'Aucune modification à enregistrer.'; end if;
    if c.user_id is not null and v_changes ? 'email' then v_cons := v_cons || 'Le client a un compte : son e-mail de connexion n''est pas modifié.'::text; end if;
    v_payload := jsonb_build_object('client_id', c.id, 'changes', v_changes);
    v_entity := 'client:' || c.id;
    v_title := 'Modifier la fiche de ' || trim(coalesce(c.first_name, '') || ' ' || coalesce(c.last_name, ''));

  -- ------------------------------------------------------- rendez-vous
  elsif p_kind = 'booking_create' then
    select * into c from clients where id = (p ->> 'client_id')::uuid and merged_into is null;
    if not found then raise exception 'Client introuvable.'; end if;
    if nullif(p ->> 'pack_id', '') is not null then
      select pk.id, pk.service_id, s2.name || ' — ' || pk.name, pk.price_cents, pk.duration_minutes into v_pack, v_svc, v_label, v_price, v_dur
        from service_packs pk join services s2 on s2.id = pk.service_id where pk.id = (p ->> 'pack_id')::uuid and pk.is_active;
    else
      select s2.id, s2.name, case when coalesce(s2.price_display_mode, 'FIXED') = 'FIXED' then s2.base_price_cents end, s2.duration_minutes into v_svc, v_label, v_price, v_dur
        from services s2 where s2.id = (p ->> 'service_id')::uuid and s2.is_active;
    end if;
    if v_svc is null then raise exception 'Prestation introuvable.'; end if;
    v_dur := coalesce(nullif(p ->> 'duration_minutes', '')::int, v_dur, 60);
    v_start := eva_hhmm_minutes(p ->> 'start');
    if nullif(p ->> 'date', '') is null or v_start is null then raise exception 'Date et heure requises.'; end if;
    if not _eva_slot_free((p ->> 'date')::date, v_start, v_dur) then
      raise exception 'Créneau indisponible (horaires, autre rendez-vous, marge de trajet ou calendrier Apple).';
    end if;
    if coalesce(p ->> 'status', 'CONFIRMED') not in ('CONFIRMED', 'PENDING') then raise exception 'Statut invalide.'; end if;
    if c.user_id is null and c.phone is null and c.email is null then raise exception 'Ce client n''a ni téléphone ni e-mail.'; end if;
    v_payload := jsonb_build_object('client_id', c.id, 'service_id', v_svc, 'pack_id', v_pack, 'label', v_label, 'date', p ->> 'date', 'start', _eva_hhmm(v_start),
      'duration', v_dur, 'price_cents', v_price, 'status', coalesce(p ->> 'status', 'CONFIRMED'), 'notes', _eva_clean(p ->> 'notes', 500));
    v_name := trim(coalesce(c.first_name, '') || ' ' || coalesce(c.last_name, ''));
    v_entity := 'client-booking:' || c.id || ':' || (p ->> 'date');
    v_title := 'Rendez-vous ' || v_label || ' — ' || v_name || ', ' || to_char((p ->> 'date')::date, 'DD/MM/YYYY') || ' à ' || _eva_hhmm(v_start);
    v_cons := array['Durée ' || v_dur || ' min. Prix : ' || coalesce(_eva_eur(v_price), 'sur devis (aucun montant inventé)') || '.',
      case when coalesce(p ->> 'status', 'CONFIRMED') = 'CONFIRMED' then 'Rendez-vous CONFIRMÉ : e-mail de confirmation au client (s''il a un e-mail) et ajout à Apple Calendar.'
           else 'Rendez-vous « à confirmer » : aucun message tant qu''il n''est pas confirmé.' end];

  elsif p_kind = 'booking_cancel' then
    select * into b from bookings where id = (p ->> 'booking_id')::uuid;
    if not found then raise exception 'Rendez-vous introuvable.'; end if;
    if b.status not in ('PENDING', 'CONFIRMED') then raise exception 'Ce rendez-vous ne peut pas être annulé (statut %).', b.status; end if;
    if coalesce(p ->> 'reason_code', '') not in ('creneau_indisponible', 'hors_zone', 'prestation_non_proposee', 'client_injoignable', 'doublon', 'erreur_reservation', 'autre') then
      raise exception 'Motif d''annulation requis.';
    end if;
    if p ->> 'reason_code' = 'autre' and _eva_clean(p ->> 'detail', 300) is null then raise exception 'Précisez le motif.'; end if;
    v_payload := jsonb_build_object('booking_id', b.id, 'reason_code', p ->> 'reason_code', 'detail', _eva_clean(p ->> 'detail', 300),
      'type', case when b.status = 'PENDING' then 'refused' else 'cancelled_admin' end);
    v_entity := 'booking:' || b.id;
    v_title := (case when b.status = 'PENDING' then 'Refuser la demande ' else 'Annuler le rendez-vous ' end) || b.reference || ' — ' ||
               _eva_client_name(b.client_id, b.customer_user_id, b.guest_name) || ', ' || to_char(b.date, 'DD/MM/YYYY') || ' à ' || _eva_hhmm(_eva_min(b.start_time));
    v_cons := array['Le rendez-vous passe en « Annulé » (rien n''est supprimé, il reste dans l''historique).',
                    'Le client est prévenu par les notifications existantes.', 'L''événement Apple Calendar est retiré.'];

  -- --------------------------------------------------------- catalogue
  elsif p_kind = 'service_create' then
    v_label := _eva_clean(p ->> 'name', 120);
    if v_label is null or char_length(v_label) < 4 then raise exception 'Nom de prestation requis.'; end if;
    if coalesce(p ->> 'category', '') not in ('plomberie', 'chauffage', 'climatisation') then raise exception 'Catégorie requise (plomberie, chauffage ou climatisation).'; end if;
    if coalesce(p ->> 'mode', '') not in ('FIXED', 'FROM', 'QUOTE') then raise exception 'Type de prix requis (prix fixe, à partir de, sur devis).'; end if;
    v_price := nullif(p ->> 'price_cents', '')::int; v_dur := nullif(p ->> 'duration_minutes', '')::int;
    if p ->> 'mode' <> 'QUOTE' and (v_price is null or v_price <= 0) then raise exception 'Prix requis : saisissez-le vous-même (EVA n''invente aucun tarif).'; end if;
    if p ->> 'mode' <> 'QUOTE' and (v_dur is null or v_dur not between 15 and 600) then raise exception 'Durée requise (15 à 600 minutes).'; end if;
    if exists (select 1 from services where _eva_norm(name) = _eva_norm(v_label)) then raise exception 'Une prestation porte déjà ce nom.'; end if;
    v_slug := p ->> 'category' || '-' || trim(both '-' from regexp_replace(_eva_norm(v_label), '[^a-z0-9]+', '-', 'g'));
    if exists (select 1 from services where slug = v_slug) then v_slug := v_slug || '-' || to_char(now(), 'YYMMDDHH24MI'); end if;
    v_payload := jsonb_build_object('name', v_label, 'category', p ->> 'category', 'mode', p ->> 'mode', 'slug', v_slug,
      'price_cents', case when p ->> 'mode' = 'QUOTE' then null else v_price end, 'duration_minutes', case when p ->> 'mode' = 'QUOTE' then null else v_dur end,
      'description', _eva_clean(p ->> 'description', 600));
    v_entity := 'service:' || v_slug;
    v_title := 'Ajouter la prestation « ' || v_label || ' »';
    v_cons := array[initcap(p ->> 'category') || ' · ' || case p ->> 'mode' when 'FIXED' then 'prix fixe ' || _eva_eur(v_price) when 'FROM' then 'à partir de ' || _eva_eur(v_price) else 'sur devis' end ||
                    coalesce(' · ' || v_dur || ' min', '') || '.',
                    'Elle est créée MASQUÉE : invisible pour vos clients tant que vous ne la publiez pas.'];

  elsif p_kind = 'service_publish' then
    select * into s from services where id = (p ->> 'service_id')::uuid;
    if not found then raise exception 'Prestation introuvable.'; end if;
    if s.is_active then raise exception 'Cette prestation est déjà publiée.'; end if;
    v_payload := jsonb_build_object('service_id', s.id);
    v_entity := 'service:' || s.slug;
    v_title := 'Publier la prestation « ' || s.name || ' »';
    v_cons := array['Elle devient visible et réservable sur le site, au tarif enregistré : ' ||
                    case coalesce(s.price_display_mode, 'FIXED') when 'QUOTE' then 'sur devis' when 'FROM' then 'à partir de ' || _eva_eur(s.base_price_cents) else _eva_eur(s.base_price_cents) end || '.'];

  -- -------------------------------------------------------------- devis
  elsif p_kind = 'quote_update' then
    v_level := 2;
    select * into q from quotes where id = (p ->> 'quote_id')::uuid;
    if not found then raise exception 'Devis introuvable.'; end if;
    if q.status <> 'DRAFT' then raise exception 'Seul un devis en brouillon peut être modifié.'; end if;
    select * into o from quote_options where id = q.selected_option_id;
    if not found then select * into o from quote_options where quote_id = q.id order by sort_order limit 1; end if;
    v_payload := jsonb_build_object('quote_id', q.id, 'option_id', o.id,
      'title', coalesce(_eva_clean(p ->> 'title', 160), q.title),
      'label', coalesce(_eva_clean(p ->> 'label', 120), o.label, 'Proposition'),
      'description', coalesce(_eva_clean(p ->> 'description', 1000), o.description),
      'supply_cents', coalesce(nullif(p ->> 'supply_cents', '')::int, o.supply_cents, 0),
      'labor_cents', coalesce(nullif(p ->> 'labor_cents', '')::int, o.labor_cents, 0),
      'travel_fee_cents', coalesce(nullif(p ->> 'travel_fee_cents', '')::int, q.travel_fee_cents, 0));
    if (v_payload ->> 'supply_cents')::int < 0 or (v_payload ->> 'labor_cents')::int < 0 or (v_payload ->> 'travel_fee_cents')::int < 0 then raise exception 'Montants invalides.'; end if;
    v_price := (v_payload ->> 'supply_cents')::int + (v_payload ->> 'labor_cents')::int;
    v_entity := 'quote:' || q.id;
    v_title := 'Modifier le devis ' || q.reference;
    v_cons := array['Fournitures ' || _eva_eur((v_payload ->> 'supply_cents')::int) || ' + main-d''œuvre ' || _eva_eur((v_payload ->> 'labor_cents')::int) ||
                    ' + déplacement ' || _eva_eur((v_payload ->> 'travel_fee_cents')::int) || ' = ' || _eva_eur(v_price + (v_payload ->> 'travel_fee_cents')::int - coalesce(q.discount_cents, 0)) ||
                    case when coalesce(q.discount_cents, 0) > 0 then ' (remise ' || _eva_eur(q.discount_cents) || ' déduite)' else '' end || '.',
                    'Les montants sont ceux que vous avez saisis ; le devis reste un brouillon.'];

  elsif p_kind = 'quote_send' then
    select * into q from quotes where id = (p ->> 'quote_id')::uuid;
    if not found then raise exception 'Devis introuvable.'; end if;
    if q.status <> 'DRAFT' then raise exception 'Seul un devis en brouillon peut être envoyé.'; end if;
    if coalesce(q.total_cents, 0) <= 0 then raise exception 'Le devis est à 0 € : complétez-le avant l''envoi.'; end if;
    if not exists (select 1 from quote_options where quote_id = q.id) then raise exception 'Le devis n''a aucune ligne.'; end if;
    v_name := coalesce((select email from clients where id = q.client_id), (select email from profiles where user_id = q.customer_user_id));
    if v_name is null then raise exception 'Le client n''a pas d''e-mail : le devis ne peut pas lui être envoyé.'; end if;
    v_payload := jsonb_build_object('quote_id', q.id);
    v_entity := 'quote:' || q.id;
    v_title := 'Envoyer le devis ' || coalesce(q.title, q.reference) || ' (' || _eva_eur(q.total_cents) || ')';
    v_cons := array['Un numéro définitif DEV-… est attribué par le serveur.', 'Le client reçoit le devis par e-mail (' || v_name || ').',
                    case when q.followups_enabled then 'Les relances automatiques prévues s''appliquent.' else 'Pas de relance automatique.' end,
                    'Le devis ne pourra plus être modifié une fois envoyé.'];

  -- -------------------------------------------------- compte rendu
  elsif p_kind = 'report_notes' then
    v_level := 2;
    select * into b from bookings where id = (p ->> 'booking_id')::uuid;
    if not found then raise exception 'Rendez-vous introuvable.'; end if;
    if not exists (select 1 from interventions where booking_id = b.id) then
      raise exception 'Aucune fiche d''intervention pour ce rendez-vous : commencez l''intervention depuis le planning.';
    end if;
    if exists (select 1 from interventions where booking_id = b.id and report_status = 'FINALIZED') then raise exception 'Compte rendu déjà validé et signé : il ne peut plus être modifié.'; end if;
    if _eva_clean(p ->> 'observations', 4000) is null and _eva_clean(p ->> 'recommendations', 4000) is null then raise exception 'Dictez ou saisissez des observations ou des recommandations.'; end if;
    v_payload := jsonb_build_object('booking_id', b.id, 'observations', _eva_clean(p ->> 'observations', 4000), 'recommendations', _eva_clean(p ->> 'recommendations', 4000));
    v_entity := 'booking:' || b.id;
    v_title := 'Compte rendu — ' || _eva_client_name(b.client_id, b.customer_user_id, b.guest_name) || ', ' || b.reference;
    v_cons := array['Observations et recommandations enregistrées dans le BROUILLON du compte rendu.',
                    'La validation, les signatures et l''envoi au client restent dans la fiche d''intervention.'];

  -- ------------------------------------------ parrainage et fidélité
  elsif p_kind = 'referrer_status' then
    select * into c from clients where id = (p ->> 'client_id')::uuid;
    if not found or not exists (select 1 from referral_codes where client_id = c.id) then raise exception 'Parrain introuvable.'; end if;
    if coalesce(p ->> 'status', '') not in ('active', 'suspended') then raise exception 'Statut invalide.'; end if;
    v_payload := jsonb_build_object('client_id', c.id, 'status', p ->> 'status');
    v_entity := 'referrer:' || c.id;
    v_title := case when p ->> 'status' = 'active' then 'Réactiver le parrain ' else 'Suspendre le parrain ' end || trim(coalesce(c.first_name, '') || ' ' || coalesce(c.last_name, ''));
    v_cons := array[case when p ->> 'status' = 'active' then 'Son code est de nouveau accepté.' else 'Son code n''est plus accepté ; ses récompenses en attente passent « à vérifier ».' end];

  elsif p_kind = 'referrer_code' then
    select * into c from clients where id = (p ->> 'client_id')::uuid;
    if not found or not exists (select 1 from referral_codes where client_id = c.id) then raise exception 'Parrain introuvable.'; end if;
    v_label := upper(regexp_replace(coalesce(p ->> 'code', ''), '\s', '', 'g'));
    if v_label !~ '^[A-Z0-9]{6,12}$' or v_label !~ '[A-Z]' then raise exception 'Code : 6 à 12 lettres ou chiffres, au moins une lettre.'; end if;
    v_payload := jsonb_build_object('client_id', c.id, 'code', v_label);
    v_entity := 'referrer:' || c.id;
    v_title := 'Changer le code de parrainage de ' || trim(coalesce(c.first_name, '') || ' ' || coalesce(c.last_name, '')) || ' en ' || v_label;
    v_cons := array['L''ancien code et l''ancien lien ne fonctionneront plus.', 'Les parrainages déjà enregistrés sont conservés.'];

  elsif p_kind = 'wallet_adjust' then
    select * into c from clients where id = (p ->> 'client_id')::uuid and merged_into is null;
    if not found then raise exception 'Client introuvable.'; end if;
    v_price := nullif(p ->> 'amount_cents', '')::int;
    if v_price is null or v_price = 0 or abs(v_price) > 100000 then raise exception 'Montant invalide.'; end if;
    if _eva_clean(p ->> 'reason', 300) is null then raise exception 'Un motif est obligatoire.'; end if;
    if v_price < 0 and coalesce((select balance_cents from wallet_balances where client_id = c.id), 0) + v_price < 0 then raise exception 'Solde insuffisant.'; end if;
    v_payload := jsonb_build_object('client_id', c.id, 'amount_cents', v_price, 'reason', _eva_clean(p ->> 'reason', 300));
    v_entity := 'wallet:' || c.id;
    v_title := (case when v_price > 0 then 'Créditer ' else 'Débiter ' end) || _eva_eur(abs(v_price)) || ' sur le crédit fidélité de ' || trim(coalesce(c.first_name, '') || ' ' || coalesce(c.last_name, ''));
    v_cons := array['Motif : ' || (v_payload ->> 'reason') || '.', 'Solde après opération : ' || _eva_eur(coalesce((select balance_cents from wallet_balances where client_id = c.id), 0) + v_price) || '.',
                    'L''opération est inscrite dans l''historique (non modifiable).'];
  else
    raise exception 'PROPOSITION_INCONNUE';
  end if;
  return jsonb_build_object('level', v_level, 'title', v_title, 'consequences', to_jsonb(v_cons), 'payload', v_payload, 'entity', v_entity);
end $$;

create or replace function public._eva_execute_ext(p_kind text, p jsonb, p_proposal uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_id uuid; c clients; v_ch jsonb; k text; v_opt uuid; v_ref text; v_status text;
begin
  if p_kind = 'client_create' then
    if exists (select 1 from clients where merged_into is null and ((p ->> 'email' is not null and lower(email) = p ->> 'email')
               or (p ->> 'phone' is not null and regexp_replace(coalesce(phone, ''), '\D', '', 'g') = regexp_replace(p ->> 'phone', '\D', '', 'g')))) then
      raise exception 'Un client avec ce téléphone ou cet e-mail a été créé entre-temps.';
    end if;
    insert into clients (first_name, last_name, phone, email, address, postal_code, city, client_type, notes)
    values (p ->> 'first_name', p ->> 'last_name', p ->> 'phone', p ->> 'email', p ->> 'address', p ->> 'postal_code', p ->> 'city', p ->> 'client_type', p ->> 'notes')
    returning id into v_id;
    return jsonb_build_object('client_id', v_id, 'client_created', true);

  elsif p_kind = 'client_update' then
    v_ch := p -> 'changes';
    for k in select jsonb_object_keys(v_ch) loop
      execute format('update clients set %I = $1, updated_at = now() where id = $2', k) using v_ch ->> k, (p ->> 'client_id')::uuid;
    end loop;
    return jsonb_build_object('client_id', p ->> 'client_id', 'client_updated', true);

  elsif p_kind = 'booking_create' then
    if not _eva_slot_free((p ->> 'date')::date, eva_hhmm_minutes(p ->> 'start'), (p ->> 'duration')::int) then raise exception 'Le créneau n''est plus disponible.'; end if;
    select * into c from clients where id = (p ->> 'client_id')::uuid;
    -- Même ligne que l'écran « Nouveau rendez-vous » de l'administration.
    insert into bookings (client_id, customer_user_id, guest_name, guest_email, guest_phone, guest_address, service_id, service_pack_id, date, start_time, status,
                          service_duration_minutes, service_price_cents, total_cents, notes)
    values (c.id, c.user_id,
            case when c.user_id is null then nullif(trim(coalesce(c.first_name, '') || ' ' || coalesce(c.last_name, '')), '') end,
            case when c.user_id is null then c.email end, case when c.user_id is null then c.phone end,
            case when c.user_id is null then nullif(trim(coalesce(c.address, '') || ' ' || coalesce(c.postal_code, '') || ' ' || coalesce(c.city, '')), '') end,
            (p ->> 'service_id')::uuid, nullif(p ->> 'pack_id', '')::uuid, (p ->> 'date')::date, (p ->> 'start')::time, p ->> 'status',
            (p ->> 'duration')::int, coalesce((p ->> 'price_cents')::int, 0), coalesce((p ->> 'price_cents')::int, 0), p ->> 'notes')
    returning id, reference into v_id, v_ref;
    return jsonb_build_object('booking_id', v_id, 'reference', v_ref, 'booking_created', true, 'status', p ->> 'status', 'date', p ->> 'date', 'start', p ->> 'start');

  elsif p_kind = 'booking_cancel' then
    -- Même mise à jour que la fenêtre « Motif d'annulation » de l'administration.
    update bookings set status = 'CANCELLED', cancelled_by = 'admin', cancelled_at = now(), cancellation_type = p ->> 'type',
           cancellation_reason_code = p ->> 'reason_code', cancellation_reason_detail = case when p ->> 'reason_code' = 'autre' then p ->> 'detail' end
     where id = (p ->> 'booking_id')::uuid and status in ('PENDING', 'CONFIRMED');
    if not found then raise exception 'Ce rendez-vous a changé entre-temps : annulation non effectuée.'; end if;
    return jsonb_build_object('booking_id', p ->> 'booking_id', 'booking_cancelled', true);

  elsif p_kind = 'service_create' then
    insert into services (slug, category, customer_type, name, description, booking_type, base_price_cents, duration_minutes, is_active, price_display_mode, sort_order)
    values (p ->> 'slug', p ->> 'category', 'particulier', p ->> 'name', p ->> 'description',
            case when p ->> 'mode' = 'QUOTE' then 'QUOTE_REQUEST' else 'DIRECT_BOOKING' end,
            nullif(p ->> 'price_cents', '')::int, nullif(p ->> 'duration_minutes', '')::int, false, p ->> 'mode', 900)
    returning id into v_id;
    return jsonb_build_object('service_id', v_id, 'service_created', true, 'name', p ->> 'name');

  elsif p_kind = 'service_publish' then
    update services set is_active = true, updated_at = now() where id = (p ->> 'service_id')::uuid and not is_active;
    if not found then raise exception 'Prestation déjà publiée ou introuvable.'; end if;
    return jsonb_build_object('service_id', p ->> 'service_id', 'service_published', true);

  elsif p_kind = 'quote_update' then
    if (select status from quotes where id = (p ->> 'quote_id')::uuid) <> 'DRAFT' then raise exception 'Le devis n''est plus un brouillon.'; end if;
    v_opt := nullif(p ->> 'option_id', '')::uuid;
    if v_opt is null then
      insert into quote_options (quote_id, label, description, supply_cents, labor_cents, sort_order)
      values ((p ->> 'quote_id')::uuid, p ->> 'label', p ->> 'description', (p ->> 'supply_cents')::int, (p ->> 'labor_cents')::int, 0) returning id into v_opt;
      update quotes set selected_option_id = v_opt where id = (p ->> 'quote_id')::uuid;
    else
      update quote_options set label = p ->> 'label', description = p ->> 'description', supply_cents = (p ->> 'supply_cents')::int, labor_cents = (p ->> 'labor_cents')::int where id = v_opt;
    end if;
    update quotes set title = p ->> 'title', travel_fee_cents = (p ->> 'travel_fee_cents')::int,
           subtotal_cents = (p ->> 'supply_cents')::int + (p ->> 'labor_cents')::int,
           total_cents = (p ->> 'supply_cents')::int + (p ->> 'labor_cents')::int + (p ->> 'travel_fee_cents')::int - coalesce(discount_cents, 0)
     where id = (p ->> 'quote_id')::uuid;
    return jsonb_build_object('quote_id', p ->> 'quote_id', 'quote_updated', true, 'total_cents', (select total_cents from quotes where id = (p ->> 'quote_id')::uuid));

  elsif p_kind = 'quote_send' then
    -- Même mise à jour que le bouton « Envoyer » : numérotation et e-mail par les déclencheurs existants.
    update quotes set status = 'SENT', sent_at = now() where id = (p ->> 'quote_id')::uuid and status = 'DRAFT' returning reference into v_ref;
    if not found then raise exception 'Le devis n''est plus un brouillon.'; end if;
    return jsonb_build_object('quote_id', p ->> 'quote_id', 'quote_sent', true, 'reference', v_ref);

  elsif p_kind = 'report_notes' then
    update interventions set observations = coalesce(p ->> 'observations', observations), recommendations = coalesce(p ->> 'recommendations', recommendations)
     where id = (select id from interventions where booking_id = (p ->> 'booking_id')::uuid order by created_at desc limit 1) and report_status = 'DRAFT';
    if not found then raise exception 'Compte rendu introuvable ou déjà validé.'; end if;
    return jsonb_build_object('booking_id', p ->> 'booking_id', 'report_saved', true);

  elsif p_kind = 'referrer_status' then
    perform admin_set_referrer_status((p ->> 'client_id')::uuid, p ->> 'status');
    return jsonb_build_object('client_id', p ->> 'client_id', 'referrer_status', p ->> 'status');

  elsif p_kind = 'referrer_code' then
    v_ch := admin_set_referrer_code((p ->> 'client_id')::uuid, p ->> 'code');
    if v_ch is not null and jsonb_typeof(v_ch) = 'object' and coalesce((v_ch ->> 'ok')::boolean, true) is false then
      raise exception '%', coalesce(v_ch ->> 'error', 'Code refusé.');
    end if;
    return jsonb_build_object('client_id', p ->> 'client_id', 'referrer_code', p ->> 'code');

  elsif p_kind = 'wallet_adjust' then
    perform admin_adjust_wallet((p ->> 'client_id')::uuid, (p ->> 'amount_cents')::int, p ->> 'reason');
    return jsonb_build_object('client_id', p ->> 'client_id', 'wallet_adjusted', true,
      'balance_cents', coalesce((select balance_cents from wallet_balances where client_id = (p ->> 'client_id')::uuid), 0));
  end if;
  raise exception 'PROPOSITION_INCONNUE';
end $$;

-- =====================================================================
-- 3) Registre des capacités mis à jour
-- =====================================================================
insert into public.eva_tools (key, agent, label, level, status, example, note, sort) values
  ('agenda_range', 'planning', 'Rendez-vous de la semaine (ou d''une période)', 1, 'disponible', 'Combien de rendez-vous ai-je cette semaine ?', null, 16),
  ('stats', 'planning', 'Statistiques de réservation', 1, 'disponible', 'Statistiques du mois', null, 17),
  ('maintenance_due', 'planning', 'Entretiens à renouveler', 1, 'disponible', 'Affiche les clients ayant un entretien à renouveler', null, 18),
  ('client_detail', 'clients', 'Fiche complète d''un client (historique, équipements)', 1, 'disponible', 'Recherche la dernière intervention chez ce client', null, 19),
  ('client_create', 'clients', 'Créer une fiche client', 2, 'disponible', 'Crée un nouveau client', 'Contrôle des doublons', 50),
  ('client_update', 'clients', 'Modifier une fiche client', 3, 'disponible', 'Modifie le téléphone de Monsieur Martin', 'Avant / après affiché', 50),
  ('booking_create', 'planning', 'Créer un rendez-vous pour un client', 3, 'disponible', 'Prends rendez-vous pour Monsieur Martin jeudi à 10 h', 'Créneau vérifié', 54),
  ('booking_cancel', 'planning', 'Annuler ou refuser un rendez-vous', 3, 'disponible', 'Annule le rendez-vous de demain matin', 'Motif obligatoire, rien n''est supprimé', 53),
  ('catalog', 'devis', 'Consulter le catalogue et les tarifs', 1, 'disponible', 'Quel est le tarif d''un détartrage ?', null, 25),
  ('service_create', 'devis', 'Ajouter une prestation (masquée, puis publication)', 3, 'disponible', 'Ajoute une prestation de remplacement de siphon', 'Prix saisi par vous', 51),
  ('quote_update', 'devis', 'Modifier un devis en brouillon', 2, 'disponible', 'Modifie le devis de Monsieur Martin', 'Montants saisis par vous', 26),
  ('quote_send', 'devis', 'Envoyer un devis au client', 3, 'disponible', 'Envoie le devis de Monsieur Dupont', 'Numéro DEV attribué, e-mail au client', 52),
  ('invoices_list', 'factures', 'Factures et paiements (par client ou période)', 1, 'disponible', 'Montre les factures de Monsieur Martin', null, 35),
  ('report', 'planning', 'Préparer le compte rendu d''une intervention', 2, 'disponible', 'Prépare le compte rendu de l''intervention de Monsieur Martin', 'Brouillon ; signatures dans la fiche', 56),
  ('referrals', 'fidelite', 'Parrains et codes de parrainage', 1, 'disponible', 'Montre mes parrains', null, 60),
  ('referrer_admin', 'fidelite', 'Suspendre, réactiver ou changer un code de parrainage', 3, 'disponible', 'Suspends le parrain Martin', null, 61),
  ('loyalty', 'fidelite', 'Crédit fidélité d''un client (consulter, créditer)', 3, 'disponible', 'Quel est le crédit fidélité de Monsieur Martin ?', 'Motif obligatoire', 62),
  ('equipment', 'clients', 'Ajouter ou modifier un équipement client', 2, 'a_developper', null, 'Consultation disponible dans la fiche client', 55),
  ('reports', 'interventions', 'Valider, signer et envoyer un compte rendu, photos', 3, 'non_realisable', null, 'Signatures et photos restent dans la fiche d''intervention (présence du client)', 57),
  ('settings', 'eva', 'Tarifs du déplacement, SMS, réglages avancés', 3, 'a_developper', null, null, 58)
on conflict (key) do update set agent = excluded.agent, label = excluded.label, level = excluded.level, status = excluded.status,
  example = excluded.example, note = excluded.note, sort = excluded.sort;

-- =====================================================================
-- 4) Droits
-- =====================================================================
do $$
declare f text;
begin
  foreach f in array array[
    'public._eva_booking_brief(public.bookings)', 'public._eva_agenda_range(date, date)', 'public._eva_stats(date, date)', 'public._eva_catalog(text, boolean)',
    'public._eva_invoices_list(uuid, text, date, date)', 'public._eva_client_detail(uuid)', 'public._eva_maintenance_due(integer)', 'public._eva_referrals(text)',
    'public._eva_loyalty(uuid)', 'public._eva_report(uuid)', 'public._eva_resolve_client(jsonb)', 'public._eva_ext_agent(text)', 'public._eva_clean(text, integer)',
    'public._eva_prepare_ext(text, jsonb)', 'public._eva_execute_ext(text, jsonb, uuid)'] loop
    execute 'revoke all on function ' || f || ' from public, anon, authenticated';
  end loop;
  execute 'revoke all on function public.eva_query(text, jsonb, text) from public, anon';
  execute 'grant execute on function public.eva_query(text, jsonb, text) to authenticated';
end $$;
