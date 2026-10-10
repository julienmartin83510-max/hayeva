-- =====================================================================
-- 0134 — PARRAINAGE : transparence, suivi détaillé et justificatifs
-- =====================================================================
-- Additif uniquement : aucune table, colonne, ligne ni code existant
-- n'est supprimé. Les 3 codes déjà attribués et le parrainage existant
-- sont conservés tels quels (le parrainage reçoit seulement sa référence).
--
-- 1) Références uniques : HAY-PAR-AAAA-NNNN (recommandation),
--    HAY-REG-AAAA-NNNN (règlement), HAY-ATT / HAY-REL / HAY-JUS
--    (attestation, relevé, justificatif).
-- 2) Règlement : moyen et date RÉELS du règlement obligatoires pour
--    passer une demande au statut « Payé ».
-- 3) Registre des documents (referral_documents) : chaque document émis
--    est figé (contenu exact + empreinte SHA-256 + code de vérification),
--    en ajout seul. Un document ne s'émet que si la situation réelle le
--    permet (relevé : récompense validée ; justificatif : règlement payé
--    avec moyen et date). Une récompense annulée (remboursement…) annule
--    automatiquement ses relevés.
-- 4) Suivi : get_my_referral_tracking() — uniquement les étapes réellement
--    confirmées, aucune donnée personnelle du client recommandé (ni nom,
--    ni coordonnées, ni prestation, ni montant payé, ni date de rendez-vous).
-- 5) E-mails : recommandation enregistrée, récompense validée, règlement
--    effectué (fonction notify-referral, anti-doublon referral_emails).
-- 0) Correctif préalable : paiement d'une facture créée depuis un rendez-vous.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 0) Correctif : facture émise directement depuis un rendez-vous
-- ---------------------------------------------------------------------
-- Depuis 0112, une facture peut être créée depuis un rendez-vous sans devis
-- (invoices.booking_id renseigné, quote_id vide). Le parrainage ne cherchait
-- la facture qu'à travers le devis : son paiement n'était jamais reconnu et
-- la recommandation restait « paiement non confirmé ». Même règle métier,
-- simplement appliquée aux deux façons de rattacher la facture.
do $FX$ declare f text; d text; n text; begin
  foreach f in array array['admin_ambassador_detail()', 'admin_apply_referee_advantage(uuid)', 'admin_confirm_payment_and_validate(uuid, integer, text, date, text, text)',
                           'referral_payment_status(uuid)', 'referral_stage_v2(uuid)'] loop
    begin
      d := pg_get_functiondef(('public.' || f)::regprocedure);
    exception when undefined_function then
      -- signature différente : on retrouve la fonction par son nom
      select pg_get_functiondef(p.oid) into d from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname = split_part(f, '(', 1);
    end;
    n := regexp_replace(d, 'from invoices i join quotes q on q\.id = i\.quote_id where q\.booking_id = ([a-z_.]+)',
                        'from invoices i left join quotes q on q.id = i.quote_id where coalesce(i.booking_id, q.booking_id) = \1', 'g');
    if n <> d then execute n; end if;
  end loop;

  d := pg_get_functiondef('public.referral_booking_payment(uuid)'::regprocedure);
  n := replace(d, E'  from invoices i\n  join quotes q on q.id = i.quote_id\n  join bookings b on b.id = q.booking_id\n  where q.booking_id = p_booking_id;',
                  E'  from invoices i\n  left join quotes q on q.id = i.quote_id\n  join bookings b on b.id = coalesce(i.booking_id, q.booking_id)\n  where coalesce(i.booking_id, q.booking_id) = p_booking_id;');
  if n <> d then execute n; end if;

  d := pg_get_functiondef('public.referral_on_invoice_status()'::regprocedure);
  n := replace(d, 'or NEW.quote_id is distinct from OLD.quote_id then', 'or NEW.quote_id is distinct from OLD.quote_id or NEW.booking_id is distinct from OLD.booking_id then');
  n := replace(n, 'select b.client_id into v_client from quotes q join bookings b on b.id = q.booking_id where q.id = NEW.quote_id;',
                  'select b.client_id into v_client from bookings b where b.id = coalesce(NEW.booking_id, (select q.booking_id from quotes q where q.id = NEW.quote_id));');
  if n <> d then execute n; end if;
end $FX$;

-- ---------------------------------------------------------------------
-- 1) Numérotation
-- ---------------------------------------------------------------------
create table if not exists public.referral_doc_counters (
  prefix text not null check (prefix in ('PAR', 'REG', 'ATT', 'REL', 'JUS')),
  year integer not null,
  last_value integer not null default 0,
  primary key (prefix, year)
);
alter table public.referral_doc_counters enable row level security;

create or replace function public.referral_next_number(p_prefix text, p_at timestamptz default now())
returns text language plpgsql security definer set search_path to 'public' as $$
declare v_year integer := extract(year from (coalesce(p_at, now()) at time zone 'Europe/Paris'))::integer; v_next integer;
begin
  insert into referral_doc_counters (prefix, year, last_value) values (p_prefix, v_year, 1)
  on conflict (prefix, year) do update set last_value = referral_doc_counters.last_value + 1
  returning last_value into v_next;
  return 'HAY-' || p_prefix || '-' || v_year || '-' || lpad(v_next::text, 4, '0');
end $$;

alter table public.referrals add column if not exists reference text;
create unique index if not exists referrals_reference_key on public.referrals (reference);
alter table public.referral_payout_requests
  add column if not exists reference text,
  add column if not exists payment_method text,
  add column if not exists payment_date date;
create unique index if not exists referral_payout_requests_reference_key on public.referral_payout_requests (reference);
do $$ begin
  alter table public.referral_payout_requests add constraint referral_payout_method_check
    check (payment_method is null or payment_method in ('virement', 'cheque', 'especes', 'autre'));
exception when duplicate_object then null; end $$;
-- Un règlement « Payé » porte toujours son moyen et sa date réels (contrôle
-- appliqué aux nouvelles écritures ; aucune ligne existante n'est réécrite).
do $$ begin
  alter table public.referral_payout_requests add constraint referral_payout_paid_details_check
    check (status <> 'PAID' or (payment_method is not null and payment_date is not null)) not valid;
exception when duplicate_object then null; end $$;

create or replace function public.referral_assign_reference()
returns trigger language plpgsql security definer set search_path to 'public' as $$
begin
  if NEW.reference is null then NEW.reference := referral_next_number('PAR', NEW.created_at); end if;
  return NEW;
end $$;
create or replace function public.referral_payout_assign_reference()
returns trigger language plpgsql security definer set search_path to 'public' as $$
begin
  if NEW.reference is null then NEW.reference := referral_next_number('REG', NEW.requested_at); end if;
  return NEW;
end $$;
drop trigger if exists trg_referrals_reference on public.referrals;
create trigger trg_referrals_reference before insert on public.referrals for each row execute function referral_assign_reference();
drop trigger if exists trg_referral_payouts_reference on public.referral_payout_requests;
create trigger trg_referral_payouts_reference before insert on public.referral_payout_requests for each row execute function referral_payout_assign_reference();

-- Références des lignes existantes, dans l'ordre chronologique réel.
do $$ declare r record; begin
  for r in select id, created_at from referrals where reference is null order by created_at, public_no loop
    update referrals set reference = referral_next_number('PAR', r.created_at) where id = r.id;
  end loop;
  for r in select id, requested_at from referral_payout_requests where reference is null order by requested_at, public_no loop
    update referral_payout_requests set reference = referral_next_number('REG', r.requested_at) where id = r.id;
  end loop;
end $$;

-- ---------------------------------------------------------------------
-- 2) Registre des documents
-- ---------------------------------------------------------------------
create table if not exists public.referral_documents (
  id uuid primary key default gen_random_uuid(),
  kind text not null check (kind in ('ATTESTATION', 'RELEVE', 'JUSTIFICATIF')),
  number text not null unique,
  referrer_client_id uuid not null references public.clients(id),
  referral_id uuid references public.referrals(id),
  reward_id uuid references public.referral_rewards(id),
  payout_id uuid references public.referral_payout_requests(id),
  content jsonb not null,
  content_sha256 text not null,
  verification_code text not null unique,
  storage_path text,
  file_sha256 text,
  issued_at timestamptz not null default now(),
  issued_by uuid,
  revoked_at timestamptz,
  revoked_reason text,
  check ((kind = 'JUSTIFICATIF') = (payout_id is not null)),
  check (kind = 'JUSTIFICATIF' or referral_id is not null)
);
create index if not exists referral_documents_owner_idx on public.referral_documents (referrer_client_id, issued_at desc);
create index if not exists referral_documents_subject_idx on public.referral_documents (kind, referral_id, payout_id, issued_at desc);
alter table public.referral_documents enable row level security;
drop policy if exists referral_documents_select on public.referral_documents;
create policy referral_documents_select on public.referral_documents for select to authenticated
  using (referrer_client_id = my_client_id() or is_admin());

-- Ajout seul : seuls le fichier (une fois) et l'annulation (une fois) peuvent être complétés.
create or replace function public.referral_documents_guard()
returns trigger language plpgsql set search_path to 'public' as $$
begin
  if TG_OP = 'DELETE' then raise exception 'Le registre des justificatifs est en ajout seul.'; end if;
  if NEW.id <> OLD.id or NEW.kind <> OLD.kind or NEW.number <> OLD.number or NEW.referrer_client_id <> OLD.referrer_client_id
     or NEW.referral_id is distinct from OLD.referral_id or NEW.reward_id is distinct from OLD.reward_id or NEW.payout_id is distinct from OLD.payout_id
     or NEW.content <> OLD.content or NEW.content_sha256 <> OLD.content_sha256 or NEW.verification_code <> OLD.verification_code
     or NEW.issued_at <> OLD.issued_at or NEW.issued_by is distinct from OLD.issued_by
     or (OLD.storage_path is not null and NEW.storage_path is distinct from OLD.storage_path)
     or (OLD.file_sha256 is not null and NEW.file_sha256 is distinct from OLD.file_sha256)
     or (OLD.revoked_at is not null and (NEW.revoked_at is distinct from OLD.revoked_at or NEW.revoked_reason is distinct from OLD.revoked_reason)) then
    raise exception 'Un justificatif émis ne peut pas être modifié.';
  end if;
  return NEW;
end $$;
drop trigger if exists trg_referral_documents_guard on public.referral_documents;
create trigger trg_referral_documents_guard before update or delete on public.referral_documents
  for each row execute function referral_documents_guard();

create or replace function public.referral_verification_code()
returns text language plpgsql volatile set search_path to 'public' as $$
declare a text := 'ABCDEFGHJKMNPQRSTUVWXYZ23456789'; b bytea := extensions.gen_random_bytes(12); s text := ''; i int;
begin
  for i in 0..11 loop s := s || substr(a, (get_byte(b, i) % 31) + 1, 1); if i in (3, 7) then s := s || '-'; end if; end loop;
  return s;
end $$;

-- ---------------------------------------------------------------------
-- 3) Libellés et chronologie (données réelles uniquement)
-- ---------------------------------------------------------------------
create or replace function public.referral_payout_method_label(p text)
returns text language sql immutable set search_path to 'public' as $$
  select case p when 'virement' then 'Virement bancaire' when 'cheque' then 'Chèque' when 'especes' then 'Espèces' when 'autre' then 'Autre' end
$$;

-- Statut lisible d'une recommandation (jamais « acquise » avant validation).
create or replace function public.referral_tracking_status(p_reward_id uuid)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
declare w referral_rewards%rowtype; s referral_settings%rowtype; v_payout referral_payout_requests%rowtype; v_key text; v_label text;
begin
  select * into w from referral_rewards where id = p_reward_id;
  if not found then return null; end if;
  select * into s from referral_settings where id;
  select * into v_payout from referral_payout_requests where id = w.payout_id;
  if w.status = 'VALIDATED' and v_payout.status = 'PAID' then v_key := 'REGLEE'; v_label := 'Récompense réglée';
  elsif w.status = 'VALIDATED' and w.clawback_alert then v_key := 'VERIFICATION'; v_label := 'Vérification en cours par HAYEVA';
  elsif w.status = 'VALIDATED' then v_key := 'VALIDEE'; v_label := 'Récompense validée — à régler';
  elsif w.status = 'REVIEW' then v_key := 'VERIFICATION'; v_label := 'Vérification en cours par HAYEVA';
  elsif w.status = 'PENDING' and w.status_code = 'AWAITING_PAYMENT' then v_key := 'EN_COURS'; v_label := 'En attente du paiement de l''intervention';
  elsif w.status = 'PENDING' and w.status_code = 'NO_BOOKING' then v_key := 'EN_COURS'; v_label := 'En attente d''une demande d''intervention';
  elsif w.status = 'PENDING' then v_key := 'EN_COURS'; v_label := referral_public_label(w.status, w.status_code, s.min_eligible_paid_cents);
  elsif w.status_code = 'REFUNDED' or w.status_code like 'REVOKED%' then v_key := 'ANNULEE'; v_label := 'Récompense annulée';
  elsif w.status = 'CANCELLED' then v_key := 'NON_RETENUE'; v_label := referral_public_label(w.status, w.status_code, s.min_eligible_paid_cents);
  else v_key := 'NON_RETENUE'; v_label := referral_public_label(w.status, w.status_code, s.min_eligible_paid_cents);
  end if;
  return jsonb_build_object('key', v_key, 'label', v_label);
end $$;

-- Étapes confirmées, datées. Aucune information sur le client recommandé
-- au-delà du fait qu'une étape a eu lieu.
create or replace function public.referral_tracking_steps(p_reward_id uuid)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
declare
  w referral_rewards%rowtype; r referrals%rowtype; b bookings%rowtype; v_pay record; p referral_payout_requests%rowtype;
  steps jsonb := '[]'::jsonb; v_date timestamptz; v_paid_on date; v_next text; v_has_b boolean;
begin
  select * into w from referral_rewards where id = p_reward_id;
  if not found then return '[]'::jsonb; end if;
  select * into r from referrals where id = w.referral_id;
  select * into p from referral_payout_requests where id = w.payout_id;
  steps := steps || jsonb_build_object('key', 'ENREGISTREE', 'label', 'Recommandation enregistrée', 'at', r.attributed_at);
  select * into b from bookings where id = w.booking_id;
  v_has_b := found;
  if not v_has_b then
    -- Rendez-vous annulé : l'évaluation détache la réservation de la récompense ;
    -- on retrouve la dernière demande de la personne recommandée depuis la recommandation.
    select x.* into b from bookings x
     where x.client_id in (select c.id from clients c where c.id = w.referee_client_id or c.merged_into = w.referee_client_id)
       and x.created_at >= r.attributed_at - interval '1 hour'
     order by x.created_at desc limit 1;
    v_has_b := found;
  end if;
  if v_has_b then
    if b.status = 'PENDING' or (b.status in ('CANCELLED', 'NO_SHOW') and not exists (select 1 from booking_status_history h where h.booking_id = b.id and h.new_status = 'CONFIRMED')) then
      steps := steps || jsonb_build_object('key', 'DEMANDE', 'label', 'Demande d''intervention enregistrée', 'at', b.created_at);
    else
      select min(h.changed_at) into v_date from booking_status_history h where h.booking_id = b.id and h.new_status = 'CONFIRMED';
      steps := steps || jsonb_build_object('key', 'RENDEZ_VOUS', 'label', 'Rendez-vous confirmé', 'at', coalesce(v_date, b.created_at));
    end if;
    if b.status in ('CANCELLED', 'NO_SHOW') then
      select max(h.changed_at) into v_date from booking_status_history h where h.booking_id = b.id and h.new_status = b.status;
      steps := steps || jsonb_build_object('key', 'ARRET', 'stop', true,
        'label', case b.status when 'NO_SHOW' then 'Rendez-vous non honoré' else 'Rendez-vous annulé' end, 'at', coalesce(v_date, b.cancelled_at, b.updated_at));
    end if;
    if b.status = 'COMPLETED' then
      select min(h.changed_at) into v_date from booking_status_history h where h.booking_id = b.id and h.new_status = 'COMPLETED';
      steps := steps || jsonb_build_object('key', 'INTERVENTION', 'label', 'Intervention réalisée', 'at', coalesce(v_date, b.updated_at));
      select * into v_pay from referral_booking_payment(b.id);
      if v_pay.has_paid then
        select max(i.paid_at) into v_date from invoices i left join quotes q on q.id = i.quote_id where coalesce(i.booking_id, q.booking_id) = b.id and i.status = 'PAID';
        steps := steps || jsonb_build_object('key', 'PAIEMENT', 'label', 'Paiement de l''intervention confirmé', 'at', v_date);
      elsif w.payment_confirmed_at is not null then
        steps := steps || jsonb_build_object('key', 'PAIEMENT', 'label', 'Paiement de l''intervention confirmé', 'at', w.payment_confirmed_at);
      end if;
    end if;
  end if;
  if w.status = 'VALIDATED' then
    steps := steps || jsonb_build_object('key', 'VALIDEE', 'label', 'Récompense validée', 'at', w.validated_at);
    if p.status = 'PAID' then
      steps := steps || jsonb_build_object('key', 'REGLEE', 'label', 'Récompense réglée', 'at', p.payment_date, 'date_only', true);
    end if;
  elsif w.status_code = 'REFUNDED' or w.status_code like 'REVOKED%' then
    steps := steps || jsonb_build_object('key', 'ARRET', 'stop', true, 'label', 'Récompense annulée', 'detail', w.status_reason, 'at', w.updated_at);
  elsif w.status = 'REJECTED' then
    steps := steps || jsonb_build_object('key', 'ARRET', 'stop', true, 'label', 'Recommandation non retenue',
      'detail', referral_public_label(w.status, w.status_code, (select min_eligible_paid_cents from referral_settings where id)), 'at', w.updated_at);
  end if;
  -- Prochaine étape attendue (information, jamais présentée comme acquise).
  v_next := case
    when w.status in ('REJECTED', 'CANCELLED') or w.status_code = 'REFUNDED' or w.status_code like 'REVOKED%' then null
    when w.status = 'VALIDATED' and coalesce(p.status, '') = 'PAID' then null
    when w.status = 'VALIDATED' then 'Règlement de la récompense'
    when w.status = 'REVIEW' then 'Vérification du dossier par HAYEVA'
    when not v_has_b then 'Demande d''intervention de la personne recommandée'
    when b.status in ('PENDING', 'CONFIRMED', 'IN_PROGRESS') then 'Réalisation de l''intervention'
    when b.status = 'COMPLETED' then 'Confirmation du paiement de l''intervention'
    else null end;
  return jsonb_build_object('steps', steps, 'next', v_next);
end $$;

-- ---------------------------------------------------------------------
-- 4) Tableau de bord du parrain (lecture seule, ses données uniquement)
-- ---------------------------------------------------------------------
create or replace function public.get_my_referral_tracking()
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
declare v_client uuid := my_client_id(); rc referral_codes%rowtype; v_bal jsonb;
begin
  if auth.uid() is null or v_client is null then return jsonb_build_object('ok', false, 'error', 'AUTH_REQUIRED'); end if;
  select * into rc from referral_codes where client_id = v_client;
  v_bal := referral_balances(v_client);
  return jsonb_build_object(
    'ok', true,
    'code', rc.code,
    'participant_type', rc.participant_type,
    'participant_status', rc.status,
    'counts', jsonb_build_object(
      'registered', (v_bal->>'clients_count')::int,
      'pending', (v_bal->>'pending_count')::int,
      'validated', (v_bal->>'validated_count')::int,
      'not_retained', (v_bal->>'rejected_count')::int),
    'amounts', jsonb_build_object(
      'acquired_cents', (v_bal->>'generated_cents')::int,
      'to_pay_cents', (v_bal->>'remaining_cents')::int,
      'paid_cents', (v_bal->>'paid_cents')::int),
    'referrals', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', rf.id,
        'reference', rf.reference,
        'registered_at', rf.attributed_at,
        'code_used', rf.code_used,
        'status', referral_tracking_status(w.id),
        'reward_cents', case when w.status = 'VALIDATED' then w.amount_cents end,
        'possible_cents', case when w.status in ('PENDING', 'REVIEW') and w.amount_known then w.amount_cents end,
        'tracking', referral_tracking_steps(w.id),
        'can_attestation', true,
        'can_releve', w.status = 'VALIDATED' and not w.clawback_alert,
        'payout_id', case when p.status = 'PAID' then p.id end,
        'payout_reference', case when p.status = 'PAID' then p.reference end
      ) order by rf.attributed_at desc)
      from referral_rewards w join referrals rf on rf.id = w.referral_id left join referral_payout_requests p on p.id = w.payout_id
      where w.referrer_client_id = v_client), '[]'::jsonb),
    'payouts', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', p.id, 'reference', p.reference, 'amount_cents', p.amount_cents, 'status', p.status,
        'requested_at', p.requested_at, 'payment_date', p.payment_date, 'method', referral_payout_method_label(p.payment_method),
        'can_justificatif', p.status = 'PAID' and p.payment_method is not null and p.payment_date is not null,
        'rewards', (select jsonb_agg(rf2.reference order by rf2.reference) from referral_rewards w2 join referrals rf2 on rf2.id = w2.referral_id where w2.payout_id = p.id)
      ) order by p.requested_at desc)
      from referral_payout_requests p where p.referrer_client_id = v_client), '[]'::jsonb),
    'documents', coalesce((
      select jsonb_agg(jsonb_build_object('id', d.id, 'kind', d.kind, 'number', d.number, 'issued_at', d.issued_at,
               'revoked', d.revoked_at is not null, 'subject', coalesce(d.content->>'referral_reference', d.content->>'payout_reference'))
             order by d.issued_at desc)
      from referral_documents d where d.referrer_client_id = v_client), '[]'::jsonb),
    'history', coalesce((
      select jsonb_agg(jsonb_build_object('at', l.created_at, 'type', l.entry_type, 'amount_cents', l.amount_cents,
               'reference', coalesce(rf.reference, p.reference)) order by l.created_at desc)
      from referral_ledger l left join referral_rewards w on w.id = l.reward_id left join referrals rf on rf.id = w.referral_id
      left join referral_payout_requests p on p.id = l.payout_id
      where l.referrer_client_id = v_client), '[]'::jsonb)
  );
end $$;

-- ---------------------------------------------------------------------
-- 5) Émission d'un justificatif (contenu figé à partir des données serveur)
-- ---------------------------------------------------------------------
create or replace function public.referral_company_identity()
returns jsonb language sql stable security definer set search_path to 'public' as $$
  select jsonb_strip_nulls(jsonb_build_object(
    'trade_name', coalesce(nullif(trim(c.trade_name), ''), 'HAYEVA'),
    'legal_name', nullif(trim(c.legal_name), ''),
    'legal_form', nullif(trim(c.legal_form), ''),
    'address', nullif(trim(concat_ws(', ', nullif(trim(c.address_line1), ''), nullif(trim(c.address_line2), ''),
                 nullif(trim(concat_ws(' ', nullif(trim(c.postal_code), ''), nullif(trim(c.city), ''))), ''))), ''),
    'siret', nullif(trim(c.siret), ''),
    'rcs', nullif(trim(c.rcs_number), ''),
    'vat_number', case when c.vat_regime = 'assujetti' then nullif(trim(c.vat_number), '') end,
    'email', nullif(trim(c.email), ''),
    'phone', nullif(trim(c.phone), ''),
    'website', nullif(trim(c.website), '')))
  from company_settings c where c.id = 1
$$;

create or replace function public.referral_beneficiary_identity(p_client uuid)
returns jsonb language sql stable security definer set search_path to 'public' as $$
  select jsonb_strip_nulls(jsonb_build_object(
    'type', coalesce(rc.participant_type, 'individual'),
    'name', nullif(trim(concat_ws(' ', c.first_name, c.last_name)), ''),
    'legal_name', case when rc.participant_type = 'business' then nullif(trim(a.legal_name), '') end,
    'siret', case when rc.participant_type = 'business' then nullif(trim(coalesce(a.siret, a.siren)), '') end,
    'address', nullif(trim(concat_ws(', ', nullif(trim(c.address), ''), nullif(trim(concat_ws(' ', nullif(trim(c.postal_code), ''), nullif(trim(c.city), ''))), ''))), '')))
  from clients c
  left join referral_codes rc on rc.client_id = c.id
  left join lateral (select legal_name, siret, siren from referral_business_applications x
                      where x.client_id = c.id and x.status = 'APPROVED' order by x.approved_at desc nulls last limit 1) a on true
  where c.id = p_client
$$;

create or replace function public.issue_referral_document(p_kind text, p_subject_id uuid)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare
  v_admin boolean := is_admin(); v_me uuid := my_client_id(); v_owner uuid;
  rf referrals%rowtype; w referral_rewards%rowtype; p referral_payout_requests%rowtype; s referral_settings%rowtype;
  v_content jsonb; v_hash text; v_prefix text; d referral_documents%rowtype; v_status jsonb;
begin
  if auth.uid() is null then return jsonb_build_object('ok', false, 'error', 'AUTH_REQUIRED'); end if;
  if p_kind not in ('ATTESTATION', 'RELEVE', 'JUSTIFICATIF') then return jsonb_build_object('ok', false, 'error', 'TYPE_INCONNU'); end if;
  select * into s from referral_settings where id;

  if p_kind in ('ATTESTATION', 'RELEVE') then
    select * into rf from referrals where id = p_subject_id;
    if not found then return jsonb_build_object('ok', false, 'error', 'INTROUVABLE'); end if;
    v_owner := rf.referrer_client_id;
    select * into w from referral_rewards where referral_id = rf.id;
  else
    select * into p from referral_payout_requests where id = p_subject_id;
    if not found then return jsonb_build_object('ok', false, 'error', 'INTROUVABLE'); end if;
    v_owner := p.referrer_client_id;
  end if;
  -- Même réponse qu'un document inexistant : on ne révèle rien des autres participants.
  if not v_admin and (v_me is null or v_owner <> v_me) then return jsonb_build_object('ok', false, 'error', 'INTROUVABLE'); end if;

  if p_kind = 'ATTESTATION' then
    v_status := referral_tracking_status(w.id);
    v_content := jsonb_build_object(
      'referral_reference', rf.reference,
      'beneficiary', referral_beneficiary_identity(v_owner),
      'company', referral_company_identity(),
      'registered_at', rf.attributed_at,
      'code_used', rf.code_used,
      'status_key', v_status->>'key',
      'status_label', v_status->>'label',
      'steps', (referral_tracking_steps(w.id))->'steps',
      'notice', 'Ce document atteste de l''enregistrement d''une recommandation auprès de HAYEVA. Il ne constitue pas une garantie de rémunération.');
    v_prefix := 'ATT';
  elsif p_kind = 'RELEVE' then
    if w.status <> 'VALIDATED' or w.clawback_alert then return jsonb_build_object('ok', false, 'error', 'RECOMPENSE_NON_VALIDEE'); end if;
    select * into p from referral_payout_requests where id = w.payout_id;
    v_content := jsonb_build_object(
      'referral_reference', rf.reference,
      'beneficiary', referral_beneficiary_identity(v_owner),
      'company', referral_company_identity(),
      'validated_at', w.validated_at,
      'amount_cents', w.amount_cents,
      'conditions', jsonb_build_array(
        'Nouveau client : aucune intervention réalisée ni facture réglée chez HAYEVA avant la recommandation.',
        'Prestation éligible au programme, réalisée puis réglée pour au moins ' || referral_euros(s.min_eligible_paid_cents) || ' TTC (avantage de bienvenue compris).',
        'Une seule récompense par nouveau client.',
        'Contrôles effectués : auto-parrainage, client déjà connu, doublons.'),
      'settlement', case when p.status = 'PAID' then 'REGLE' else 'A_REGLER' end,
      'payout_reference', case when p.status = 'PAID' then p.reference end,
      'payment_date', case when p.status = 'PAID' then p.payment_date end,
      'is_business', coalesce((select participant_type from referral_codes where client_id = v_owner), 'individual') = 'business',
      'notice', case when coalesce((select participant_type from referral_codes where client_id = v_owner), 'individual') = 'business'
        then 'Relevé de commission d''apport d''affaires. Ce document n''est pas une facture.'
        else 'Relevé de récompense de parrainage. Ce document n''est pas une facture.' end);
    v_prefix := 'REL';
  else
    if p.status <> 'PAID' or p.payment_method is null or p.payment_date is null then
      return jsonb_build_object('ok', false, 'error', 'REGLEMENT_NON_CONFIRME');
    end if;
    v_content := jsonb_build_object(
      'payout_reference', p.reference,
      'beneficiary', referral_beneficiary_identity(v_owner),
      'company', referral_company_identity(),
      'payment_date', p.payment_date,
      'amount_cents', p.amount_cents,
      'method', referral_payout_method_label(p.payment_method),
      'rewards', coalesce((select jsonb_agg(jsonb_build_object('reference', rf2.reference, 'amount_cents', w2.amount_cents) order by rf2.reference)
                  from referral_rewards w2 join referrals rf2 on rf2.id = w2.referral_id where w2.payout_id = p.id), '[]'::jsonb),
      'notice', 'Justificatif du règlement effectué par HAYEVA au titre du programme de parrainage.');
    v_prefix := 'JUS';
  end if;

  v_hash := encode(extensions.digest(v_content::text, 'sha256'), 'hex');
  -- Situation inchangée : on renvoie le même document (même numéro).
  select * into d from referral_documents x
   where x.kind = p_kind and x.revoked_at is null
     and (case when p_kind = 'JUSTIFICATIF' then x.payout_id = p.id else x.referral_id = rf.id end)
   order by x.issued_at desc limit 1;
  if found and d.content_sha256 = v_hash then
    return jsonb_build_object('ok', true, 'reused', true, 'id', d.id, 'kind', d.kind, 'number', d.number,
      'verification_code', d.verification_code, 'issued_at', d.issued_at, 'content', d.content, 'has_file', d.storage_path is not null);
  end if;
  insert into referral_documents (kind, number, referrer_client_id, referral_id, reward_id, payout_id, content, content_sha256, verification_code, issued_by)
  values (p_kind, referral_next_number(v_prefix), v_owner,
          case when p_kind <> 'JUSTIFICATIF' then rf.id end, case when p_kind <> 'JUSTIFICATIF' then w.id end,
          case when p_kind = 'JUSTIFICATIF' then p.id end, v_content, v_hash, referral_verification_code(), auth.uid())
  returning * into d;
  return jsonb_build_object('ok', true, 'reused', false, 'id', d.id, 'kind', d.kind, 'number', d.number,
    'verification_code', d.verification_code, 'issued_at', d.issued_at, 'content', d.content, 'has_file', false);
end $$;

-- Rattachement du PDF généré par le serveur (fonction notify / document, clé de service uniquement).
create or replace function public.referral_document_attach_file(p_id uuid, p_path text, p_sha256 text)
returns void language sql security definer set search_path to 'public' as $$
  update referral_documents set storage_path = p_path, file_sha256 = p_sha256 where id = p_id and storage_path is null;
$$;

-- Vérification publique d'un justificatif (aucune coordonnée, initiales seulement).
create or replace function public.verify_referral_document(p_code text)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
declare d referral_documents%rowtype; v_name text; v_initials text;
begin
  select * into d from referral_documents where verification_code = upper(trim(coalesce(p_code, '')));
  if not found then return jsonb_build_object('found', false); end if;
  v_name := coalesce(d.content->'beneficiary'->>'legal_name', d.content->'beneficiary'->>'name', '');
  select string_agg(left(x, 1) || '.', ' ') into v_initials from regexp_split_to_table(trim(v_name), '\s+') x where x <> '';
  return jsonb_strip_nulls(jsonb_build_object(
    'found', true,
    'kind', d.kind,
    'kind_label', case d.kind when 'ATTESTATION' then 'Attestation de recommandation' when 'RELEVE' then 'Relevé de récompense' else 'Justificatif de règlement' end,
    'number', d.number,
    'issued_at', d.issued_at,
    'beneficiary_initials', v_initials,
    'subject', coalesce(d.content->>'referral_reference', d.content->>'payout_reference'),
    'status_label', d.content->>'status_label',
    -- Aucun montant ni nom complet : le détenteur du document compare
    -- simplement la référence, la date, le type et le statut.
    'revoked', d.revoked_at is not null,
    'revoked_at', d.revoked_at,
    'revoked_reason', d.revoked_reason,
    'superseded', exists (select 1 from referral_documents n where n.kind = d.kind and n.issued_at > d.issued_at
                            and n.referral_id is not distinct from d.referral_id and n.payout_id is not distinct from d.payout_id)));
end $$;

-- Récompense validée puis annulée (remboursement, rendez-vous supprimé…) :
-- ses relevés sont annulés dans le registre, avec le motif.
create or replace function public.referral_revoke_documents_on_reward_change()
returns trigger language plpgsql security definer set search_path to 'public' as $$
begin
  if OLD.status = 'VALIDATED' and NEW.status <> 'VALIDATED' then
    update referral_documents set revoked_at = now(), revoked_reason = coalesce(NEW.status_reason, 'Récompense annulée')
     where reward_id = NEW.id and kind = 'RELEVE' and revoked_at is null;
  end if;
  return NEW;
end $$;
drop trigger if exists trg_referral_revoke_documents on public.referral_rewards;
create trigger trg_referral_revoke_documents after update of status on public.referral_rewards
  for each row execute function referral_revoke_documents_on_reward_change();

create or replace function public.admin_revoke_referral_document(p_id uuid, p_reason text)
returns void language plpgsql security definer set search_path to 'public' as $$
begin
  if not is_admin() then raise exception 'Accès réservé à l''administration.'; end if;
  if coalesce(trim(p_reason), '') = '' then raise exception 'Un motif est obligatoire.'; end if;
  update referral_documents set revoked_at = now(), revoked_reason = trim(p_reason) where id = p_id and revoked_at is null;
  if not found then raise exception 'Document introuvable ou déjà annulé.'; end if;
end $$;

create or replace function public.admin_list_referral_documents(p_client_id uuid)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
begin
  if not is_admin() then raise exception 'Accès réservé à l''administration.'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('id', d.id, 'kind', d.kind, 'number', d.number, 'issued_at', d.issued_at,
           'subject', coalesce(d.content->>'referral_reference', d.content->>'payout_reference'), 'verification_code', d.verification_code,
           'revoked_at', d.revoked_at, 'revoked_reason', d.revoked_reason, 'has_file', d.storage_path is not null) order by d.issued_at desc)
    from referral_documents d where d.referrer_client_id = p_client_id), '[]'::jsonb);
end $$;

-- ---------------------------------------------------------------------
-- 6) Règlement réel : moyen et date obligatoires
-- ---------------------------------------------------------------------
create or replace function public.admin_record_referral_payout(p_payout_id uuid, p_method text, p_payment_date date,
  p_payment_reference text default null, p_note text default null)
returns text language plpgsql security definer set search_path to 'public' as $$
declare p referral_payout_requests%rowtype;
begin
  if not is_admin() then raise exception 'Accès réservé à l''administration.'; end if;
  if coalesce(p_method, '') not in ('virement', 'cheque', 'especes', 'autre') then raise exception 'Moyen de règlement requis.'; end if;
  if p_payment_date is null or p_payment_date > (now() at time zone 'Europe/Paris')::date then raise exception 'Date de règlement invalide.'; end if;
  select * into p from referral_payout_requests where id = p_payout_id for update;
  if not found then raise exception 'Demande introuvable.'; end if;
  if p.status <> 'APPROVED' then raise exception 'Seule une demande approuvée peut être réglée (statut actuel : %).', p.status; end if;
  if p_payment_date < (p.requested_at at time zone 'Europe/Paris')::date then raise exception 'La date de règlement précède la demande.'; end if;
  update referral_payout_requests set payment_method = p_method, payment_date = p_payment_date where id = p.id;
  return admin_set_referral_payout_status(p.id, 'PAID', p_note, p_payment_reference);
end $$;

-- Garde-fou sur l'ancienne fonction : « Payé » seulement avec moyen et date réels.
do $M$ declare d text; n text; begin
  d := pg_get_functiondef('public.admin_set_referral_payout_status(uuid, text, text, text)'::regprocedure);
  if position('Indiquez le moyen et la date réels' in d) > 0 then return; end if;
  n := replace(d, E'  if p_status = ''PAID'' and exists (select 1 from referral_rewards where payout_id = p.id and (status <> ''VALIDATED'' or clawback_alert)) then',
    E'  if p_status = ''PAID'' and (p.payment_method is null or p.payment_date is null) then\n    raise exception ''Indiquez le moyen et la date réels du règlement.'';\n  end if;\n  if p_status = ''PAID'' and exists (select 1 from referral_rewards where payout_id = p.id and (status <> ''VALIDATED'' or clawback_alert)) then');
  if n = d then raise exception 'Remplacement impossible : admin_set_referral_payout_status'; end if;
  execute n;
end $M$;

-- Règlement manuel de primes : même exigence (nouvelle signature, l'ancienne est remplacée).
drop function if exists public.admin_mark_rewards_paid(uuid[], text, text);
create or replace function public.admin_mark_rewards_paid(p_reward_ids uuid[], p_reference text default null, p_note text default null,
  p_method text default null, p_payment_date date default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v_client uuid; v_n int; v_total int; v_id uuid; v_no bigint; v_ref text;
begin
  if not is_admin() then raise exception 'Accès réservé à l''administration.'; end if;
  if p_reward_ids is null or array_length(p_reward_ids, 1) is null then raise exception 'Aucune prime sélectionnée.'; end if;
  if coalesce(p_method, '') not in ('virement', 'cheque', 'especes', 'autre') then raise exception 'Moyen de règlement requis.'; end if;
  if p_payment_date is null or p_payment_date > (now() at time zone 'Europe/Paris')::date then raise exception 'Date de règlement invalide.'; end if;
  perform 1 from referral_rewards where id = any(p_reward_ids) for update;
  select count(distinct referrer_client_id), min(referrer_client_id::text)::uuid into v_n, v_client from referral_rewards where id = any(p_reward_ids);
  if v_n <> 1 then raise exception 'Les primes doivent appartenir à un seul parrain.'; end if;
  if exists (select 1 from referral_rewards where id = any(p_reward_ids) and (status <> 'VALIDATED' or payout_id is not null or clawback_alert)) then
    raise exception 'Seules des primes validées, non réglées et hors demande de versement peuvent être marquées payées.';
  end if;
  select coalesce(sum(amount_cents), 0) into v_total from referral_rewards where id = any(p_reward_ids);
  insert into referral_payout_requests (referrer_client_id, amount_cents, status, approved_at, paid_at, payment_reference, admin_note, processed_by, payment_method, payment_date)
  values (v_client, v_total, 'PAID', now(), now(), nullif(trim(coalesce(p_reference, '')), ''), coalesce(nullif(trim(coalesce(p_note, '')), ''), 'Règlement manuel'), auth.uid(), p_method, p_payment_date)
  returning id, public_no, reference into v_id, v_no, v_ref;
  update referral_rewards set payout_id = v_id, updated_at = now() where id = any(p_reward_ids);
  insert into referral_ledger (referrer_client_id, payout_id, entry_type, amount_cents, detail, created_by)
  values (v_client, v_id, 'payout_paid', v_total, jsonb_build_object('manual', true, 'reward_ids', to_jsonb(p_reward_ids), 'reference', p_reference,
          'payment_method', p_method, 'payment_date', p_payment_date), auth.uid());
  perform referral_notify_client(v_client, 'payout_paid', 'Prime réglée', 'Le règlement de ' || referral_euros(v_total) || ' a été enregistré.', 'payout_paid:' || v_id);
  return jsonb_build_object('ok', true, 'payout_no', v_no, 'reference', v_ref, 'amount_cents', v_total);
end $$;

-- ---------------------------------------------------------------------
-- 7) E-mails automatiques (3 événements), journal anti-doublon
-- ---------------------------------------------------------------------
create table if not exists public.referral_emails (
  id uuid primary key default gen_random_uuid(),
  notification_id uuid not null unique references public.referral_notifications(id),
  kind text not null,
  recipient_email text,
  status text not null default 'pending' check (status in ('pending', 'sent', 'failed', 'skipped')),
  error_message text,
  created_at timestamptz not null default now(),
  sent_at timestamptz
);
alter table public.referral_emails enable row level security;
drop policy if exists referral_emails_admin_select on public.referral_emails;
create policy referral_emails_admin_select on public.referral_emails for select to authenticated using (is_admin());

create or replace function public.referral_email_on_notification()
returns trigger language plpgsql security definer set search_path to 'public' as $$
declare v_secret text;
begin
  if NEW.kind not in ('new_referral', 'reward_validated', 'payout_paid') then return NEW; end if;
  select decrypted_secret into v_secret from vault.decrypted_secrets where name = 'webhook_secret';
  if v_secret is null then return NEW; end if;
  perform net.http_post(
    url := 'https://hvlzdsuyhrhaflwutwml.supabase.co/functions/v1/notify-referral',
    headers := jsonb_build_object('Content-Type', 'application/json', 'Authorization', 'Bearer ' || v_secret),
    body := jsonb_build_object('notification_id', NEW.id));
  return NEW;
end $$;
drop trigger if exists trg_referral_email_on_notification on public.referral_notifications;
create trigger trg_referral_email_on_notification after insert on public.referral_notifications
  for each row execute function referral_email_on_notification();

-- Contexte d'un e-mail (lu par la fonction notify-referral avec la clé de
-- service) : uniquement des données du parrain et du programme, jamais celles
-- du client recommandé.
create or replace function public.referral_email_context(p_notification_id uuid)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
declare n referral_notifications%rowtype; c clients%rowtype; v_email text; v_key text; w referral_rewards%rowtype; rf referrals%rowtype; p referral_payout_requests%rowtype;
begin
  select * into n from referral_notifications where id = p_notification_id;
  if not found or n.kind not in ('new_referral', 'reward_validated', 'payout_paid') then return null; end if;
  select * into c from clients where id = n.client_id;
  v_email := coalesce(nullif(trim(c.email), ''), (select email from profiles where user_id = c.user_id));
  v_key := split_part(n.dedupe_key, ':', 2);
  if n.kind in ('new_referral', 'reward_validated') and v_key ~ '^[0-9a-f-]{36}$' then
    select * into w from referral_rewards where id = v_key::uuid;
    select * into rf from referrals where id = w.referral_id;
  elsif n.kind = 'payout_paid' and v_key ~ '^[0-9a-f-]{36}$' then
    select * into p from referral_payout_requests where id = v_key::uuid;
  end if;
  return jsonb_strip_nulls(jsonb_build_object(
    'kind', n.kind,
    'recipient_email', v_email,
    'first_name', nullif(trim(c.first_name), ''),
    'code', (select code from referral_codes where client_id = c.id),
    'referral_reference', rf.reference,
    'registered_at', rf.attributed_at,
    'status', case when w.id is not null then referral_tracking_status(w.id) end,
    'reward_validated', w.status = 'VALIDATED',
    'reward_cents', case when w.status = 'VALIDATED' then w.amount_cents end,
    'validated_at', w.validated_at,
    'payout_reference', p.reference,
    'payout_paid', p.status = 'PAID' and p.payment_method is not null and p.payment_date is not null,
    'payout_cents', p.amount_cents,
    'payment_date', p.payment_date,
    'method', referral_payout_method_label(p.payment_method),
    'rewards', case when p.id is not null then (select jsonb_agg(rf2.reference order by rf2.reference) from referral_rewards w2 join referrals rf2 on rf2.id = w2.referral_id where w2.payout_id = p.id) end));
end $$;

-- Archive privée des PDF émis (lecture et écriture par le serveur uniquement).
insert into storage.buckets (id, name, public) values ('referral-documents', 'referral-documents', false) on conflict (id) do nothing;

-- Fiche parrain de l'administration : références et règlement réel visibles.
do $AD$ declare d text; n text; begin
  d := pg_get_functiondef('public.admin_ambassador_detail(uuid)'::regprocedure);
  if position('''reference'', rf.reference' in d) > 0 then return; end if;
  n := replace(d, '''referral_id'', rf.id,', '''referral_id'', rf.id, ''reference'', rf.reference,');
  n := replace(n, 'jsonb_build_object(''id'', p.id, ''no'', p.public_no,', 'jsonb_build_object(''id'', p.id, ''no'', p.public_no, ''reference'', p.reference, ''payment_method'', p.payment_method, ''payment_date'', p.payment_date,');
  if n = d or position('''reference'', p.reference' in n) = 0 then raise exception 'Remplacement impossible : admin_ambassador_detail'; end if;
  execute n;
end $AD$;

-- ---------------------------------------------------------------------
-- 8) Droits
-- ---------------------------------------------------------------------
revoke all on public.referral_doc_counters, public.referral_documents, public.referral_emails from anon;
revoke insert, update, delete, truncate on public.referral_documents, public.referral_emails, public.referral_doc_counters from authenticated;
grant select on public.referral_documents to authenticated;

do $$ declare f text; begin
  foreach f in array array[
    'public.referral_next_number(text, timestamptz)', 'public.referral_assign_reference()', 'public.referral_payout_assign_reference()', 'public.referral_documents_guard()',
    'public.referral_verification_code()', 'public.referral_payout_method_label(text)', 'public.referral_tracking_status(uuid)',
    'public.referral_tracking_steps(uuid)', 'public.get_my_referral_tracking()', 'public.referral_company_identity()',
    'public.referral_beneficiary_identity(uuid)', 'public.issue_referral_document(text, uuid)', 'public.referral_document_attach_file(uuid, text, text)',
    'public.verify_referral_document(text)', 'public.referral_revoke_documents_on_reward_change()', 'public.admin_revoke_referral_document(uuid, text)',
    'public.admin_list_referral_documents(uuid)', 'public.admin_record_referral_payout(uuid, text, date, text, text)',
    'public.admin_mark_rewards_paid(uuid[], text, text, text, date)', 'public.referral_email_on_notification()', 'public.referral_email_context(uuid)'] loop
    execute format('revoke all on function %s from public, anon, authenticated', f);
  end loop;
end $$;
grant execute on function public.get_my_referral_tracking() to authenticated;
grant execute on function public.issue_referral_document(text, uuid) to authenticated;
grant execute on function public.verify_referral_document(text) to anon, authenticated;
grant execute on function public.admin_revoke_referral_document(uuid, text) to authenticated;
grant execute on function public.admin_list_referral_documents(uuid) to authenticated;
grant execute on function public.admin_record_referral_payout(uuid, text, date, text, text) to authenticated;
grant execute on function public.admin_mark_rewards_paid(uuid[], text, text, text, date) to authenticated;
grant execute on function public.referral_document_attach_file(uuid, text, text) to service_role;
grant execute on function public.referral_email_context(uuid) to service_role;
