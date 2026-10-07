-- PARRAINAGE — finalisation (sur l'existant, aucune nouvelle architecture)
-- 1) Étape lisible du cycle de vie + statut de paiement par parrainage.
-- 2) Compteurs réels par parrain (utilisations, réservations générées,
--    interventions réalisées) et statistiques globales (conversions, coût).
-- 3) Recherche par téléphone, identité détaillée dans la fiche.
-- 4) Confirmation du paiement : trace « ancien statut → nouveau statut ».
-- 5) Demandes « Devenir parrain » (particuliers) : même file de demandes que
--    les apporteurs, statut À VALIDER, jamais de parrain actif automatique ;
--    formulaire public fermé par défaut (interrupteur dédié, désactivé).

alter table public.referral_settings
  add column if not exists individual_applications_public_enabled boolean not null default false;

alter table public.referral_business_applications
  add column if not exists applicant_type text not null default 'business',
  add column if not exists first_name text,
  add column if not exists last_name text;
alter table public.referral_business_applications add constraint referral_business_applications_applicant_type_check
  check (applicant_type in ('individual', 'business'));

-- Étape du cycle de vie (affichage administration).
create or replace function public.referral_stage(p_status text, p_code text, p_booking_status text, p_payout_status text)
returns text
language sql
immutable
as $$
  select case
    when p_status = 'VALIDATED' and p_payout_status = 'PAID' then 'VERSEE'
    when p_status = 'VALIDATED' then 'VALIDEE'
    when p_status = 'REJECTED' then 'REFUSE'
    when p_status = 'CANCELLED' then 'ANNULE'
    when p_status = 'REVIEW' then 'A_VALIDER'
    when p_code in ('AWAITING_PAYMENT', 'CALCULATION_OFF') then 'PAIEMENT_EN_ATTENTE'
    when p_booking_status = 'PENDING' then 'RESERVATION_CREEE'
    when p_booking_status in ('CONFIRMED', 'IN_PROGRESS') then 'INTERVENTION_PLANIFIEE'
    when p_booking_status = 'COMPLETED' then 'INTERVENTION_TERMINEE'
    else 'DETECTE' end;
$$;

-- Statut du paiement de l'intervention liée à un parrainage.
create or replace function public.referral_payment_status(p_reward_id uuid)
returns text
language plpgsql
stable
security definer
set search_path = public
as $$
declare w referral_rewards%rowtype; v_pay record; v_bstatus text;
begin
  select * into w from referral_rewards where id = p_reward_id;
  if not found or w.booking_id is null then return 'AUCUNE_INTERVENTION'; end if;
  select status into v_bstatus from bookings where id = w.booking_id;
  select * into v_pay from referral_booking_payment(w.booking_id);
  if v_pay.has_paid and v_pay.paid_net_cents <= 0 then return 'REMBOURSE'; end if;
  if v_pay.has_paid then return 'PAYE_FACTURE'; end if;
  if w.payment_method is not null and w.validation_source = 'admin' then return 'PAYE_CONFIRME'; end if;
  if exists (select 1 from invoices i join quotes q on q.id = i.quote_id where q.booking_id = w.booking_id and i.status = 'ISSUED') then return 'FACTURE_IMPAYEE'; end if;
  if v_bstatus = 'COMPLETED' then return 'EN_ATTENTE'; end if;
  return 'NON_EXIGIBLE';
end;
$$;

-- Activité réelle d'un parrain (filleuls, réservations, interventions).
create or replace function public.referral_referrer_activity(p_client uuid)
returns table (uses_count int, bookings_count int, interventions_count int, eligible_count int)
language sql
stable
security definer
set search_path = public
as $$
  with refs as (
    select rf.id, rf.attributed_at, array(select c.id from clients c where c.id = rf.referee_client_id or c.merged_into = rf.referee_client_id) ids
      from referrals rf where rf.referrer_client_id = p_client)
  select (select count(*) from refs)::int,
         (select count(*) from refs r join bookings b on b.client_id = any(r.ids) and b.created_at >= r.attributed_at - interval '1 hour')::int,
         (select count(*) from refs r join bookings b on b.client_id = any(r.ids) and b.created_at >= r.attributed_at - interval '1 hour' and b.status = 'COMPLETED')::int,
         (select count(*) from refs r join bookings b on b.client_id = any(r.ids) and b.created_at >= r.attributed_at - interval '1 hour'
                 join services sv on sv.id = b.service_id where b.status = 'COMPLETED' and coalesce(sv.referral_eligible, false))::int;
$$;

-- Demande publique « Devenir parrain » (particulier).
create or replace function public.submit_referrer_application(
  p_first_name text, p_last_name text, p_email text, p_phone text, p_terms_accepted boolean)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  s referral_settings%rowtype;
  v_email text := lower(trim(coalesce(p_email, '')));
  v_first text := trim(coalesce(p_first_name, '')); v_last text := trim(coalesce(p_last_name, ''));
  v_phone text := trim(coalesce(p_phone, ''));
  v_id uuid; v_no bigint;
begin
  select * into s from referral_settings where id;
  if not (s.is_enabled and s.individual_applications_public_enabled) then return jsonb_build_object('ok', false, 'error', 'INDISPONIBLE'); end if;
  if not coalesce(p_terms_accepted, false) then return jsonb_build_object('ok', false, 'error', 'CONDITIONS'); end if;
  if length(v_first) < 1 or length(v_last) < 1 or length(v_first) > 80 or length(v_last) > 80 then return jsonb_build_object('ok', false, 'error', 'NOM'); end if;
  if v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' or length(v_email) > 200 then return jsonb_build_object('ok', false, 'error', 'EMAIL'); end if;
  if length(regexp_replace(v_phone, '[^0-9]', '', 'g')) < 9 or length(v_phone) > 30 then return jsonb_build_object('ok', false, 'error', 'TELEPHONE'); end if;
  if (select count(*) from referral_business_applications where created_at > now() - interval '1 hour') >= 20 then
    return jsonb_build_object('ok', false, 'error', 'TROP_DE_DEMANDES');
  end if;
  begin
    insert into referral_business_applications (applicant_type, first_name, last_name, legal_name, contact_name, email, phone, terms_version, terms_accepted_at)
    values ('individual', v_first, v_last, v_first || ' ' || v_last, v_first || ' ' || v_last, v_email, v_phone, 'programme-parrainage', now())
    returning id, public_no into v_id, v_no;
  exception when unique_violation then
    return jsonb_build_object('ok', true);
  end;
  perform admin_notify('new_request', 'Demande « Devenir parrain »', 'Demande n°' || v_no || ' — ' || v_first || ' ' || v_last, null, 'referrer-app:' || v_id, true);
  return jsonb_build_object('ok', true);
end;
$$;

-- Validation d'une demande (particulier ou apporteur) : ACCEPTER crée/active
-- le parrain avec un code unique ; jamais automatique.
create or replace function public.admin_set_business_application_status(p_id uuid, p_status text, p_note text default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare a referral_business_applications%rowtype; v_client uuid; v_first text; v_last text;
begin
  if not is_admin() then raise exception 'Accès réservé à l''administration.'; end if;
  if p_status not in ('RECEIVED', 'TO_VERIFY', 'APPROVED', 'REFUSED', 'SUSPENDED') then raise exception 'Statut invalide.'; end if;
  select * into a from referral_business_applications where id = p_id for update;
  if not found then raise exception 'Demande introuvable.'; end if;
  v_client := a.client_id;
  if p_status = 'APPROVED' then
    if a.applicant_type = 'individual' then
      v_first := a.first_name; v_last := a.last_name;
    else
      v_first := split_part(coalesce(a.contact_name, a.legal_name), ' ', 1);
      v_last := nullif(trim(substring(coalesce(a.contact_name, a.legal_name) from length(v_first) + 1)), '');
    end if;
    if v_client is null then v_client := find_or_create_client(null, a.email, a.phone, v_first, v_last, null); end if;
    if exists (select 1 from referral_codes where client_id = v_client) then
      update referral_codes set participant_type = a.applicant_type, status = 'active', updated_at = now() where client_id = v_client;
    else
      insert into referral_codes (client_id, code, participant_type, status, created_by)
      values (v_client, generate_referral_code_for(v_client), a.applicant_type, 'active', auth.uid());
    end if;
  elsif p_status in ('REFUSED', 'SUSPENDED') and v_client is not null then
    perform admin_set_referrer_status(v_client, 'suspended');
  end if;
  update referral_business_applications set status = p_status, client_id = v_client,
         admin_note = case when nullif(trim(coalesce(p_note, '')), '') is not null then concat_ws(' | ', admin_note, p_note) else admin_note end,
         reviewed_by = auth.uid(), reviewed_at = now(),
         approved_at = case when p_status = 'APPROVED' then coalesce(approved_at, now()) else approved_at end,
         updated_at = now()
   where id = a.id;
  insert into referral_events (event, detail) values ('ADMIN_APPLICATION_' || p_status, jsonb_build_object('application_id', a.id, 'type', a.applicant_type, 'client_id', v_client, 'by', auth.uid()));
  return jsonb_build_object('ok', true, 'client_id', v_client, 'code', (select code from referral_codes where client_id = v_client));
end;
$$;

create or replace function public.admin_update_referral_settings(p jsonb)
returns referral_settings
language plpgsql
security definer
set search_path = public
as $$
declare r referral_settings%rowtype;
begin
  if not is_admin() then raise exception 'Accès réservé à l''administration.'; end if;
  update referral_settings set
    is_enabled = coalesce((p->>'is_enabled')::boolean, is_enabled),
    referee_reward_cents = coalesce((p->>'referee_reward_cents')::int, referee_reward_cents),
    min_eligible_paid_cents = coalesce((p->>'min_eligible_paid_cents')::int, min_eligible_paid_cents),
    min_payout_cents = coalesce((p->>'min_payout_cents')::int, min_payout_cents),
    ambassador_public_enabled = coalesce((p->>'ambassador_public_enabled')::boolean, ambassador_public_enabled),
    individual_applications_public_enabled = coalesce((p->>'individual_applications_public_enabled')::boolean, individual_applications_public_enabled),
    business_program_public_enabled = coalesce((p->>'business_program_public_enabled')::boolean, business_program_public_enabled),
    payouts_enabled = coalesce((p->>'payouts_enabled')::boolean, payouts_enabled),
    booking_code_entry_enabled = coalesce((p->>'booking_code_entry_enabled')::boolean, booking_code_entry_enabled),
    manual_creation_enabled = coalesce((p->>'manual_creation_enabled')::boolean, manual_creation_enabled),
    reward_calculation_enabled = coalesce((p->>'reward_calculation_enabled')::boolean, reward_calculation_enabled),
    annual_tracking_threshold_cents = case when p ? 'annual_tracking_threshold_cents' then nullif((p->>'annual_tracking_threshold_cents')::int, 0) else annual_tracking_threshold_cents end,
    updated_at = now(), updated_by = auth.uid()
  where id returning * into r;
  insert into referral_events (event, detail) values ('ADMIN_SETTINGS_SAVED', p || jsonb_build_object('by', auth.uid()));
  return r;
end;
$$;

create or replace function public.get_referral_public_config()
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object(
    'program_enabled', s.is_enabled,
    'booking_code_entry_enabled', s.booking_code_entry_enabled,
    'ambassador_public_enabled', s.ambassador_public_enabled,
    'individual_applications_public_enabled', s.individual_applications_public_enabled,
    'business_program_public_enabled', s.business_program_public_enabled,
    'payouts_enabled', s.payouts_enabled,
    'reward_cents', (select fixed_cents from referral_reward_rules where scope_type = 'default' and is_active and mode = 'fixed'),
    'reward_rules_uniform', not exists (select 1 from referral_reward_rules where is_active and (scope_type <> 'default' or mode <> 'fixed')),
    'min_eligible_paid_cents', s.min_eligible_paid_cents,
    'min_payout_cents', s.min_payout_cents)
  from referral_settings s where s.id;
$$;

create or replace function public.admin_list_referrers(p_search text default null, p_filter text default 'all')
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare q text := nullif(lower(trim(coalesce(p_search, ''))), ''); s referral_settings%rowtype; v_year_start timestamptz;
begin
  if not is_admin() then raise exception 'Accès réservé à l''administration.'; end if;
  select * into s from referral_settings where id;
  v_year_start := date_trunc('year', now() at time zone 'Europe/Paris') at time zone 'Europe/Paris';
  return coalesce((
    select jsonb_agg(x order by (x->>'last_activity') desc nulls last) from (
      select jsonb_build_object(
        'client_id', c.id, 'name', trim(coalesce(c.first_name, '') || ' ' || coalesce(c.last_name, '')), 'first_name', c.first_name, 'last_name', c.last_name,
        'email', c.email, 'phone', c.phone, 'created_at', rc.created_at,
        'uses_count', act.uses_count, 'bookings_count', act.bookings_count, 'interventions_count', act.interventions_count,
        'code', rc.code, 'link', 'https://hayeva.fr/rdv?ref=' || rc.code, 'participant_type', rc.participant_type, 'status', rc.status,
        'clients_count', (bb.b->>'clients_count')::int, 'validated_count', (bb.b->>'validated_count')::int, 'pending_count', (bb.b->>'pending_count')::int,
        'rejected_count', (bb.b->>'rejected_count')::int, 'pending_cents', (bb.b->>'pending_cents')::int, 'available_cents', (bb.b->>'available_cents')::int,
        'reserved_cents', (bb.b->>'reserved_cents')::int, 'paid_cents', (bb.b->>'paid_cents')::int, 'generated_cents', (bb.b->>'generated_cents')::int,
        'remaining_cents', (bb.b->>'remaining_cents')::int, 'paid_year_cents', y.paid_year_cents, 'review_count', rv.review_count,
        'alerts', to_jsonb(array_remove(array[
            case when rc.status = 'suspended' then 'SUSPENDU' end,
            case when rv.review_count > 0 then 'A_VERIFIER' end,
            case when s.annual_tracking_threshold_cents is not null and y.paid_year_cents >= s.annual_tracking_threshold_cents then 'SEUIL_SUIVI_ANNUEL' end,
            case when rc.participant_type = 'business' and not exists (select 1 from referral_business_applications ba where ba.client_id = c.id and ba.status = 'APPROVED' and (ba.siren is not null or ba.siret is not null)) then 'INFOS_ADMINISTRATIVES' end
          ], null)),
        'last_activity', greatest(rc.created_at, rc.updated_at, (select max(w.updated_at) from referral_rewards w where w.referrer_client_id = c.id))) x
      from referral_codes rc join clients c on c.id = rc.client_id
      cross join lateral (select referral_balances(c.id) as b) bb
      cross join lateral (select coalesce((select sum(p.amount_cents) from referral_payout_requests p where p.referrer_client_id = c.id and p.status = 'PAID' and p.paid_at >= v_year_start), 0) paid_year_cents) y
      cross join lateral (select (select count(*) from referral_rewards w where w.referrer_client_id = c.id and (w.status = 'REVIEW' or w.clawback_alert)) review_count) rv
      cross join lateral (select * from referral_referrer_activity(c.id)) act
      where (q is null
          or lower(trim(coalesce(c.first_name, '') || ' ' || coalesce(c.last_name, ''))) like '%' || q || '%'
          or lower(rc.code) like '%' || q || '%'
          or exists (select 1 from referral_code_history h where h.client_id = c.id and lower(h.code) like '%' || q || '%')
          or lower(coalesce(c.email, '')) like '%' || q || '%'
          or (length(regexp_replace(q, '[^0-9]', '', 'g')) >= 4
              and right(regexp_replace(coalesce(c.phone, ''), '[^0-9]', '', 'g'), 9) like '%' || right(regexp_replace(q, '[^0-9]', '', 'g'), 9) || '%')
          or exists (select 1 from referral_rewards w join referrals rf on rf.id = w.referral_id left join bookings bk on bk.id = w.booking_id
                      where w.referrer_client_id = c.id
                        and (lower(coalesce(bk.reference, '')) like '%' || q || '%' or ('client #' || rf.public_no) like '%' || q || '%' or rf.public_no::text = q)))
        and (coalesce(p_filter, 'all') = 'all'
          or (p_filter = 'individual' and rc.participant_type = 'individual')
          or (p_filter = 'business' and rc.participant_type = 'business')
          or (p_filter = 'review' and rv.review_count > 0)
          or (p_filter = 'suspended' and rc.status = 'suspended')
          or (p_filter = 'available' and (bb.b->>'available_cents')::int > 0)
          or (p_filter = 'to_pay' and (bb.b->>'remaining_cents')::int > 0)
          or (p_filter = 'reserved' and (bb.b->>'reserved_cents')::int > 0))
    ) t), '[]'::jsonb);
end;
$$;

create or replace function public.admin_ambassador_detail(p_client_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare rc referral_codes%rowtype; v_year_start timestamptz;
begin
  if not is_admin() then raise exception 'Accès réservé à l''administration.'; end if;
  select * into rc from referral_codes where client_id = p_client_id;
  v_year_start := date_trunc('year', now() at time zone 'Europe/Paris') at time zone 'Europe/Paris';
  return jsonb_build_object(
    'client', (select jsonb_build_object('id', c.id, 'name', trim(coalesce(c.first_name, '') || ' ' || coalesce(c.last_name, '')),
                 'first_name', c.first_name, 'last_name', c.last_name, 'email', c.email, 'phone', c.phone)
                 from clients c where c.id = p_client_id),
    'code', rc.code,
    'link', case when rc.code is not null then 'https://hayeva.fr/rdv?ref=' || rc.code end,
    'old_codes', coalesce((select jsonb_agg(jsonb_build_object('code', h.code, 'retired_at', h.retired_at) order by h.retired_at desc) from referral_code_history h where h.client_id = p_client_id), '[]'::jsonb),
    'participant_type', rc.participant_type,
    'status', rc.status,
    'created_at', rc.created_at,
    'balances', referral_balances(p_client_id),
    'activity', (select to_jsonb(a) from referral_referrer_activity(p_client_id) a),
    'paid_year_cents', coalesce((select sum(amount_cents) from referral_payout_requests where referrer_client_id = p_client_id and status = 'PAID' and paid_at >= v_year_start), 0),
    'application', (select jsonb_build_object('no', a.public_no, 'legal_name', a.legal_name, 'siren', a.siren, 'siret', a.siret, 'status', a.status, 'approved_at', a.approved_at)
                      from referral_business_applications a where a.client_id = p_client_id order by a.created_at desc limit 1),
    'rewards', coalesce((
      select jsonb_agg(jsonb_build_object('id', w.id, 'ref', 'Client #' || rf.public_no, 'status', w.status, 'code', w.status_code,
               'display_status', case when p.status = 'PAID' then 'PAID' else w.status end,
               'reason', w.status_reason, 'flags', w.review_flags, 'amount_cents', w.amount_cents, 'amount_known', w.amount_known,
               'paid_amount_cents', w.paid_amount_cents, 'booking_total_cents', b.total_cents,
               'referee', trim(coalesce(f.first_name, '') || ' ' || coalesce(f.last_name, '')), 'code_used', rf.code_used,
               'booking_ref', b.reference, 'booking_status', b.status, 'booking_date', b.date, 'service', sv.name,
               'validation_source', w.validation_source, 'validated_at', w.validated_at, 'payout_no', p.public_no, 'payout_status', p.status,
               'paid_at', case when p.status = 'PAID' then p.paid_at end, 'clawback', w.clawback_alert,
               'referrer_type', w.referrer_type, 'created_at', w.created_at,
               'stage', referral_stage(w.status, w.status_code, b.status, p.status),
               'payment_status', referral_payment_status(w.id),
               'payment_method', w.payment_method, 'payment_date', w.payment_date, 'payment_reference', w.payment_reference,
               'history', coalesce((select jsonb_agg(jsonb_build_object('event', e.event, 'at', e.created_at, 'detail', e.detail) order by e.created_at)
                                     from referral_events e where e.referral_id = w.referral_id), '[]'::jsonb)) order by w.created_at desc)
        from referral_rewards w join referrals rf on rf.id = w.referral_id join clients f on f.id = w.referee_client_id
        left join bookings b on b.id = w.booking_id left join services sv on sv.id = b.service_id
        left join referral_payout_requests p on p.id = w.payout_id
       where w.referrer_client_id = p_client_id), '[]'::jsonb),
    'payouts', coalesce((
      select jsonb_agg(jsonb_build_object('id', p.id, 'no', p.public_no, 'amount_cents', p.amount_cents, 'status', p.status,
               'requested_at', p.requested_at, 'paid_at', p.paid_at, 'refusal_reason', p.refusal_reason, 'admin_note', p.admin_note,
               'payment_reference', p.payment_reference) order by p.requested_at desc)
        from referral_payout_requests p where p.referrer_client_id = p_client_id), '[]'::jsonb),
    'events', coalesce((
      select jsonb_agg(jsonb_build_object('event', e.event, 'at', e.created_at, 'detail', e.detail) order by e.created_at desc)
        from (select * from referral_events e where e.detail->>'client_id' = p_client_id::text order by created_at desc limit 50) e), '[]'::jsonb),
    'ledger', coalesce((
      select jsonb_agg(jsonb_build_object('type', l.entry_type, 'amount_cents', l.amount_cents, 'created_at', l.created_at, 'detail', l.detail) order by l.created_at desc)
        from (select * from referral_ledger where referrer_client_id = p_client_id order by created_at desc limit 100) l), '[]'::jsonb)
  );
end;
$$;

create or replace function public.admin_referral_dashboard()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if not is_admin() then raise exception 'Accès réservé à l''administration.'; end if;
  return jsonb_build_object(
    'settings', (select to_jsonb(s) - 'updated_by' from referral_settings s where s.id),
    'rules', coalesce((select jsonb_agg(to_jsonb(r) - 'updated_by' order by case r.scope_type when 'default' then 1 when 'category' then 2 else 3 end, r.scope_value) from referral_reward_rules r), '[]'::jsonb),
    'services', coalesce((select jsonb_agg(jsonb_build_object('slug', slug, 'name', name, 'category', category) order by category, name) from services where is_active), '[]'::jsonb),
    'categories', coalesce((select jsonb_agg(distinct category) from services where is_active), '[]'::jsonb),
    'ambassadors_total', (select count(*) from referral_codes),
    'ambassadors_active', (select count(distinct referrer_client_id) from referral_rewards),
    'individuals_count', (select count(*) from referral_codes where participant_type = 'individual'),
    'business_count', (select count(*) from referral_codes where participant_type = 'business'),
    'suspended_count', (select count(*) from referral_codes where status = 'suspended'),
    'applications_open', (select count(*) from referral_business_applications where status in ('RECEIVED', 'TO_VERIFY')),
    'new_clients', (select count(*) from referral_rewards),
    'code_uses', (select count(*) from referrals),
    'bookings_generated', (select coalesce(sum(a.bookings_count), 0) from referral_codes rc2 cross join lateral referral_referrer_activity(rc2.client_id) a),
    'interventions_done', (select coalesce(sum(a.interventions_count), 0) from referral_codes rc2 cross join lateral referral_referrer_activity(rc2.client_id) a),
    'converted_count', (select count(*) from referral_rewards where status = 'VALIDATED' and not clawback_alert),
    'paid_rewards_cents', coalesce((select sum(w.amount_cents) from referral_rewards w join referral_payout_requests p on p.id = w.payout_id where p.status = 'PAID'), 0),
    'referee_credits_cents', coalesce((select sum(amount_cents) from wallet_transactions where type = 'REFERRAL_REFEREE'), 0)
                             + coalesce((select sum(amount_cents) from wallet_transactions where type = 'ADJUSTMENT' and referral_id is not null), 0),
    'program_cost_cents', coalesce((select sum(amount_cents) from referral_rewards where status = 'VALIDATED'), 0)
                          + coalesce((select sum(amount_cents) from wallet_transactions where type = 'REFERRAL_REFEREE'), 0)
                          + coalesce((select sum(amount_cents) from wallet_transactions where type = 'ADJUSTMENT' and referral_id is not null), 0),
    'pending_count', (select count(*) from referral_rewards where status in ('PENDING', 'REVIEW')),
    'review_count', (select count(*) from referral_rewards where status = 'REVIEW' or (status = 'PENDING' and status_code in ('AWAITING_PAYMENT', 'CALCULATION_OFF')) or clawback_alert),
    'validated_count', (select count(*) from referral_rewards where status = 'VALIDATED'),
    'rejected_count', (select count(*) from referral_rewards where status in ('REJECTED', 'CANCELLED')),
    'generated_cents', coalesce((select sum(amount_cents) from referral_rewards where status = 'VALIDATED'), 0),
    'remaining_cents', coalesce((select sum(w.amount_cents) from referral_rewards w left join referral_payout_requests p on p.id = w.payout_id where w.status = 'VALIDATED' and not w.clawback_alert and (p.id is null or p.status <> 'PAID')), 0),
    'available_cents', coalesce((select sum(amount_cents) from referral_rewards where status = 'VALIDATED' and payout_id is null and not clawback_alert), 0),
    'payouts_requested', (select count(*) from referral_payout_requests where status in ('REQUESTED', 'REVIEWING', 'APPROVED')),
    'to_pay_cents', coalesce((select sum(amount_cents) from referral_payout_requests where status in ('REQUESTED', 'REVIEWING', 'APPROVED')), 0),
    'paid_cents', coalesce((select sum(amount_cents) from referral_payout_requests where status = 'PAID'), 0),
    'to_verify', coalesce((
      select jsonb_agg(x order by x->>'created_at') from (
        select jsonb_build_object('reward_id', rw.id, 'ref', 'Client #' || rf.public_no, 'status', rw.status, 'code', rw.status_code,
                 'reason', rw.status_reason, 'flags', rw.review_flags, 'clawback', rw.clawback_alert, 'referrer_type', rw.referrer_type,
                 'referrer', trim(coalesce(a.first_name, '') || ' ' || coalesce(a.last_name, '')), 'referrer_client_id', rw.referrer_client_id,
                 'referee', trim(coalesce(f.first_name, '') || ' ' || coalesce(f.last_name, '')), 'service', sv.name,
                 'booking_ref', bk.reference, 'booking_status', bk.status, 'paid_amount_cents', rw.paid_amount_cents,
                 'amount_cents', case when rw.amount_known then rw.amount_cents end, 'created_at', rw.created_at) x
          from referral_rewards rw join referrals rf on rf.id = rw.referral_id
          join clients a on a.id = rw.referrer_client_id join clients f on f.id = rw.referee_client_id
          left join bookings bk on bk.id = rw.booking_id left join services sv on sv.id = bk.service_id
         where rw.status = 'REVIEW' or (rw.status = 'PENDING' and rw.status_code in ('AWAITING_PAYMENT', 'CALCULATION_OFF')) or rw.clawback_alert) t), '[]'::jsonb),
    'payouts', coalesce((
      select jsonb_agg(jsonb_build_object('id', p.id, 'no', p.public_no, 'amount_cents', p.amount_cents, 'status', p.status,
               'requested_at', p.requested_at, 'paid_at', p.paid_at, 'admin_note', p.admin_note, 'payment_reference', p.payment_reference,
               'referrer', trim(coalesce(a.first_name, '') || ' ' || coalesce(a.last_name, '')), 'referrer_client_id', p.referrer_client_id,
               'participant_type', (select participant_type from referral_codes where client_id = p.referrer_client_id),
               'email', a.email, 'phone', a.phone) order by p.requested_at desc)
        from referral_payout_requests p join clients a on a.id = p.referrer_client_id where p.status in ('REQUESTED', 'REVIEWING', 'APPROVED')), '[]'::jsonb),
    'applications', coalesce((
      select jsonb_agg(jsonb_build_object('id', a.id, 'no', a.public_no, 'applicant_type', a.applicant_type, 'first_name', a.first_name, 'last_name', a.last_name,
               'legal_name', a.legal_name, 'contact_name', a.contact_name,
               'email', a.email, 'phone', a.phone, 'siren', a.siren, 'siret', a.siret, 'message', a.message, 'status', a.status,
               'created_at', a.created_at, 'admin_note', a.admin_note, 'client_id', a.client_id) order by a.created_at desc)
        from (select * from referral_business_applications order by created_at desc limit 100) a), '[]'::jsonb)
  );
end;
$$;


create or replace function public.admin_confirm_payment_and_validate(
  p_reward_id uuid, p_paid_cents integer, p_method text, p_payment_date date, p_reference text default null, p_note text default null)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare w referral_rewards%rowtype; s referral_settings%rowtype; v_booking uuid; v_ins int; v_final int; v_pay record; b bookings%rowtype;
begin
  if not is_admin() then raise exception 'Accès réservé à l''administration.'; end if;
  select * into s from referral_settings where id;
  select * into w from referral_rewards where id = p_reward_id for update;
  if not found then raise exception 'Prime introuvable.'; end if;
  if w.status = 'VALIDATED' then return 'ALREADY_VALIDATED'; end if;
  if w.status not in ('PENDING', 'REVIEW') then raise exception 'Cette prime n''est plus validable (statut %).', w.status; end if;
  if coalesce(p_method, '') not in ('virement', 'carte', 'especes', 'cheque', 'autre') then raise exception 'Moyen de paiement requis.'; end if;
  if p_payment_date is null or p_payment_date > (now() at time zone 'Europe/Paris')::date then raise exception 'Date de paiement invalide.'; end if;
  if coalesce(p_paid_cents, 0) < s.min_eligible_paid_cents then
    raise exception 'Montant payé inférieur au seuil de % : aucune récompense.', referral_euros(s.min_eligible_paid_cents);
  end if;
  if w.booking_id is not null and exists (select 1 from bookings where id = w.booking_id and status = 'COMPLETED') then
    v_booking := w.booking_id;
  else
    select x.id into v_booking from bookings x join services sv on sv.id = x.service_id
     where x.client_id in (select id from clients where id = w.referee_client_id or merged_into = w.referee_client_id)
       and x.status = 'COMPLETED' and coalesce(sv.referral_eligible, false)
     order by x.date, x.start_time limit 1;
  end if;
  if v_booking is null then raise exception 'Aucune intervention terminée pour ce filleul : validation impossible.'; end if;
  select * into b from bookings where id = v_booking;
  if p_payment_date < b.date - 30 then raise exception 'Date de paiement incohérente avec l''intervention du %.', to_char(b.date, 'DD/MM/YYYY'); end if;
  -- Une facture existe pour ce RDV : c'est elle qui fait foi.
  select * into v_pay from referral_booking_payment(v_booking);
  if v_pay.has_paid then
    raise exception 'Une facture payée existe pour cette intervention : la récompense est validée automatiquement à partir de la facture (utilisez « Revérifier »).';
  elsif exists (select 1 from invoices i join quotes q on q.id = i.quote_id where q.booking_id = v_booking and i.status = 'ISSUED') then
    raise exception 'Une facture non payée existe pour cette intervention : enregistrez d''abord son paiement dans Factures.';
  end if;
  if exists (select 1 from referral_rewards x where x.booking_id = v_booking and x.status = 'VALIDATED' and x.id <> w.id) then
    raise exception 'Cette intervention a déjà généré une récompense.';
  end if;
  v_final := referral_compute_reward(v_booking, p_paid_cents);
  if v_final <= 0 then raise exception 'Aucune règle de récompense active pour cette prestation : configurez-la dans Parrainages > Configuration.'; end if;
  insert into referral_ledger (referrer_client_id, reward_id, entry_type, amount_cents, detail, created_by)
  values (w.referrer_client_id, w.id, 'reward_validated', v_final,
          jsonb_build_object('booking_id', v_booking, 'paid_amount_cents', p_paid_cents, 'source', 'admin', 'payment_method', p_method,
                             'payment_date', p_payment_date, 'payment_reference', p_reference, 'note', p_note,
                             'old_status', w.status || '/' || w.status_code, 'new_status', 'VALIDATED/ADMIN_VALIDATED', 'admin_id', auth.uid()), auth.uid())
  on conflict do nothing;
  get diagnostics v_ins = row_count;
  if v_ins = 0 then return 'ALREADY_VALIDATED'; end if;
  update referral_rewards set status = 'VALIDATED', status_code = 'ADMIN_VALIDATED',
         status_reason = 'Paiement confirmé par l''administration (' || p_method || ', ' || to_char(p_payment_date, 'DD/MM/YYYY') || ')',
         booking_id = v_booking, paid_amount_cents = p_paid_cents, validation_source = 'admin', amount_cents = v_final, amount_known = true,
         payment_method = p_method, payment_date = p_payment_date, payment_reference = nullif(trim(coalesce(p_reference, '')), ''),
         payment_confirmed_by = auth.uid(), payment_confirmed_at = now(),
         validated_at = now(), validated_by = auth.uid(), updated_at = now()
   where id = w.id;
  insert into referral_events (referral_id, event, detail)
  values (w.referral_id, 'PAYMENT_CONFIRMED', jsonb_build_object('reward_id', w.id, 'booking_id', v_booking, 'paid_amount_cents', p_paid_cents,
          'reward_cents', v_final, 'payment_method', p_method, 'payment_date', p_payment_date, 'payment_reference', p_reference,
          'from', w.status || '/' || w.status_code, 'to', 'VALIDATED/ADMIN_VALIDATED', 'by', auth.uid()));
  perform _referral_after_validation(w.id);
  return 'VALIDATED';
end;
$$;

revoke all on function public.referral_payment_status(uuid) from public, anon, authenticated;
revoke all on function public.referral_referrer_activity(uuid) from public, anon, authenticated;
revoke all on function public.referral_stage(text, text, text, text) from public, anon;
grant execute on function public.submit_referrer_application(text, text, text, text, boolean) to anon, authenticated;
