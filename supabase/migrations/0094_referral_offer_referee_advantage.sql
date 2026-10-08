-- PARRAINAGE — offre finale : avantage filleul sur la 1re prestation,
-- configuration commerciale, cycle de vie complet, traçabilité.
--
-- * Filleul : avantage (référence 20 €, configurable) déduit de sa PREMIÈRE
--   prestation éligible (réduction de la réservation, visible avant
--   validation) — une seule fois, jamais en argent, jamais cumulé avec une
--   autre réduction (sauf décision de l'admin), jamais une prestation
--   gratuite. Remplace l'ancien crédit cagnotte versé après coup.
-- * Si la réservation portant l'avantage est annulée / client absent :
--   l'avantage redevient disponible pour la prochaine réservation éligible.
-- * Fraude / auto-parrainage / client existant / refus admin : avantage annulé
--   (réduction retirée d'une réservation non terminée).
-- * Parrain : récompense inchangée (paiement confirmé obligatoire) ; le seuil
--   minimum s'apprécie sur le montant de la prestation (payé + avantage).
-- * Configuration : avantage filleul (montant + actif), récompense parrain,
--   montant minimum, nouveaux parrains autorisés, conditions À VALIDER
--   (aucune activation publique tant qu'elles ne sont pas validées).

alter table public.referral_settings
  add column if not exists referee_advantage_enabled boolean not null default true,
  add column if not exists terms_validated boolean not null default false,
  add column if not exists terms_validated_at timestamptz,
  add column if not exists terms_validated_by uuid;

alter table public.referrals
  add column if not exists referee_advantage_cents integer,
  add column if not exists referee_advantage_status text,
  add column if not exists referee_advantage_booking_id uuid,
  add column if not exists referee_advantage_applied_at timestamptz,
  add column if not exists referee_advantage_used_at timestamptz;
alter table public.referrals add constraint referrals_referee_advantage_status_check
  check (referee_advantage_status is null or referee_advantage_status in ('NONE', 'AVAILABLE', 'APPLIED', 'USED', 'CANCELLED'));

alter table public.bookings
  add column if not exists referral_advantage_cents integer not null default 0;
alter table public.bookings add constraint bookings_referral_advantage_cents_check
  check (referral_advantage_cents >= 0);

-- Seule exception à la protection des montants : l'application / le retrait
-- de l'avantage filleul par les fonctions serveur du parrainage.
create or replace function public.protect_booking_financial_fields()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if not (is_admin() or auth.role() = 'service_role') then
    if coalesce(current_setting('app.referral_advantage', true), '') <> 'on' then
      new.service_price_cents := old.service_price_cents;
      new.travel_fee_cents := old.travel_fee_cents;
      new.discount_cents := old.discount_cents;
      new.total_cents := old.total_cents;
      new.referral_advantage_cents := old.referral_advantage_cents;
    end if;
    new.service_duration_minutes := old.service_duration_minutes;
    if coalesce(current_setting('app.allow_status_change', true), '') <> 'on' then
      new.status := old.status;
    end if;
    new.intervention_lat := old.intervention_lat;
    new.intervention_lng := old.intervention_lng;
    new.one_way_distance_km := old.one_way_distance_km;
    new.included_radius_km := old.included_radius_km;
    new.travel_rate_per_km_cents := old.travel_rate_per_km_cents;
    new.distance_calculation_status := old.distance_calculation_status;
    new.distance_calculated_at := old.distance_calculated_at;
    new.admin_viewed_at := old.admin_viewed_at;
  end if;
  return new;
end;
$$;

-- Avantage filleul effectivement déduit d'une réservation.
create or replace function public.referral_booking_advantage(p_booking uuid)
returns integer
language sql
stable
security definer
set search_path = public
as $$
  select coalesce((select referral_advantage_cents from bookings where id = p_booking), 0);
$$;

-- Modification contrôlée de la réduction d'une réservation (avantage filleul).
create or replace function public._referral_set_booking_discount(p_booking uuid, p_discount integer, p_advantage integer)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  perform set_config('app.referral_advantage', 'on', true);
  update bookings set discount_cents = greatest(p_discount, 0), referral_advantage_cents = greatest(p_advantage, 0),
         total_cents = coalesce(service_price_cents, 0) + coalesce(travel_fee_cents, 0) - greatest(p_discount, 0)
   where id = p_booking;
  perform set_config('app.referral_advantage', '', true);
end;
$$;

-- Contrôles d'un code pour un futur filleul (mêmes règles que _attach_referral,
-- sans rien enregistrer).
create or replace function public.referral_code_check(p_referee uuid, p_code text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_code text := upper(regexp_replace(coalesce(p_code, ''), '\s', '', 'g'));
  v_referrer uuid; ref_c clients%rowtype; ree_c clients%rowtype; s referral_settings%rowtype;
begin
  select * into s from referral_settings where id;
  if not (s.is_enabled and s.booking_code_entry_enabled) then return jsonb_build_object('ok', false, 'error', 'PROGRAMME_INACTIF'); end if;
  select client_id into v_referrer from referral_codes where code = v_code and status = 'active';
  if v_referrer is null then return jsonb_build_object('ok', false, 'error', 'CODE_INVALIDE'); end if;
  select * into ref_c from clients where id = v_referrer;
  select * into ree_c from clients where id = p_referee;
  if v_referrer = p_referee
     or (ref_c.user_id is not null and ref_c.user_id = ree_c.user_id)
     or (nullif(lower(trim(ref_c.email)), '') is not null and lower(trim(ref_c.email)) = lower(trim(ree_c.email)))
     or (nullif(regexp_replace(coalesce(ref_c.phone, ''), '[^0-9]', '', 'g'), '') is not null
         and right(regexp_replace(coalesce(ref_c.phone, ''), '[^0-9]', '', 'g'), 9) = right(regexp_replace(coalesce(ree_c.phone, ''), '[^0-9]', '', 'g'), 9)) then
    return jsonb_build_object('ok', false, 'error', 'AUTO_PARRAINAGE');
  end if;
  if exists (select 1 from referrals where referee_client_id = p_referee) then return jsonb_build_object('ok', false, 'error', 'DEJA_PARRAINE'); end if;
  if exists (select 1 from referrals where referee_client_id = v_referrer and referrer_client_id = p_referee) then return jsonb_build_object('ok', false, 'error', 'PARRAINAGE_CIRCULAIRE'); end if;
  if exists (select 1 from bookings where client_id = p_referee and status = 'COMPLETED')
     or exists (select 1 from invoices where client_id = p_referee and status = 'PAID') then
    return jsonb_build_object('ok', false, 'error', 'CLIENT_DEJA_EXISTANT');
  end if;
  return jsonb_build_object('ok', true, 'referrer', v_referrer);
end;
$$;

-- Application de l'avantage à la création d'une réservation (avant
-- l'insertion : montants justes dès la confirmation et l'e-mail).
create or replace function public.referral_booking_advantage_on_insert()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  s referral_settings%rowtype; v_code text := nullif(current_setting('app.referral_code', true), '');
  v_ref referrals%rowtype; v_amt int; v_gross int; v_elig boolean;
begin
  if NEW.client_id is null or NEW.status not in ('PENDING', 'CONFIRMED') then return NEW; end if;
  select * into s from referral_settings where id;
  if not (s.is_enabled and s.referee_advantage_enabled) or coalesce(s.referee_reward_cents, 0) <= 0 then return NEW; end if;
  if coalesce(NEW.discount_cents, 0) <> 0 then return NEW; end if; -- non cumulable
  select coalesce(sv.referral_eligible, false) into v_elig from services sv where sv.id = NEW.service_id;
  v_gross := coalesce(NEW.service_price_cents, 0) + coalesce(NEW.travel_fee_cents, 0);
  if not coalesce(v_elig, false) or v_gross < s.min_eligible_paid_cents then return NEW; end if;
  select * into v_ref from referrals where referee_client_id = NEW.client_id;
  if found then
    -- Avantage encore disponible (1re réservation annulée…) : uniquement tant
    -- qu'aucune prestation du filleul n'a été réalisée (1re prestation).
    if v_ref.referee_advantage_status = 'AVAILABLE' and v_ref.status <> 'INELIGIBLE'
       and not exists (select 1 from bookings x where x.client_id = NEW.client_id and x.status = 'COMPLETED') then
      v_amt := v_ref.referee_advantage_cents;
    end if;
  elsif v_code is not null and coalesce((referral_code_check(NEW.client_id, v_code)->>'ok')::boolean, false) then
    v_amt := s.referee_reward_cents;
  end if;
  if coalesce(v_amt, 0) > 0 then
    v_amt := least(v_amt, v_gross - 100); -- jamais une prestation gratuite
    if v_amt > 0 then
      NEW.discount_cents := v_amt;
      NEW.referral_advantage_cents := v_amt;
      NEW.total_cents := v_gross - v_amt;
    end if;
  end if;
  return NEW;
end;
$$;
create or replace trigger trg_bookings_zzz_referral_advantage
  before insert on public.bookings
  for each row execute function public.referral_booking_advantage_on_insert();

-- Machine d'état de l'avantage filleul.
create or replace function public.referral_sync_referee_advantage(p_referral uuid)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  r referrals%rowtype; s referral_settings%rowtype; w referral_rewards%rowtype; b bookings%rowtype; x record;
  v_ids uuid[]; v_new text; v_fraud boolean;
begin
  select * into r from referrals where id = p_referral for update;
  if not found then return null; end if;
  select * into s from referral_settings where id;
  if r.referee_advantage_status is null then
    update referrals set referee_advantage_cents = case when s.referee_advantage_enabled then coalesce(s.referee_reward_cents, 0) else 0 end,
           referee_advantage_status = case when s.referee_advantage_enabled and coalesce(s.referee_reward_cents, 0) > 0 then 'AVAILABLE' else 'NONE' end
     where id = r.id returning * into r;
  end if;
  if r.referee_advantage_status in ('USED', 'CANCELLED') then return r.referee_advantage_status; end if;
  select * into w from referral_rewards where referral_id = r.id;
  select array_agg(id) into v_ids from clients where id = r.referee_client_id or merged_into = r.referee_client_id;
  v_fraud := coalesce(w.status_code, '') in ('SELF_REFERRAL', 'EXISTING_CLIENT', 'ADMIN_REJECTED', 'ADMIN_CANCELLED');
  if v_fraud then
    for x in select id, discount_cents, referral_advantage_cents from bookings
              where client_id = any(v_ids) and referral_advantage_cents > 0 and status <> 'COMPLETED' loop
      perform _referral_set_booking_discount(x.id, x.discount_cents - x.referral_advantage_cents, 0);
    end loop;
    update referrals set referee_advantage_status = 'CANCELLED', referee_advantage_booking_id = null where id = r.id;
    insert into referral_events (referral_id, event, detail) values (r.id, 'ADVANTAGE_CANCELLED', jsonb_build_object('code', w.status_code));
    return 'CANCELLED';
  end if;
  if r.referee_advantage_status = 'NONE' then return 'NONE'; end if;
  select * into b from bookings where client_id = any(v_ids) and referral_advantage_cents > 0 and status not in ('CANCELLED', 'NO_SHOW')
   order by created_at limit 1;
  if found then
    v_new := case when b.status = 'COMPLETED' then 'USED' else 'APPLIED' end;
  else
    v_new := 'AVAILABLE';
  end if;
  if v_new is distinct from r.referee_advantage_status or b.id is distinct from r.referee_advantage_booking_id then
    update referrals set referee_advantage_status = v_new, referee_advantage_booking_id = b.id,
           referee_advantage_applied_at = case when v_new in ('APPLIED', 'USED') then coalesce(referee_advantage_applied_at, now()) else null end,
           referee_advantage_used_at = case when v_new = 'USED' then now() else null end
     where id = r.id;
    insert into referral_events (referral_id, event, detail)
    values (r.id, 'ADVANTAGE_' || v_new, jsonb_build_object('booking_id', b.id, 'cents', b.referral_advantage_cents));
  end if;
  return v_new;
end;
$$;

-- Après la création d'une réservation : rattachement de l'avantage, ou
-- retrait s'il n'est finalement pas légitime (le code n'a pas été rattaché).
create or replace function public.referral_reconcile_booking_advantage(p_booking uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare b bookings%rowtype; r referrals%rowtype;
begin
  select * into b from bookings where id = p_booking;
  if not found or b.referral_advantage_cents <= 0 then return; end if;
  select * into r from referrals where referee_client_id = b.client_id;
  if not found or r.status = 'INELIGIBLE' or coalesce(r.referee_advantage_status, '') in ('CANCELLED', 'USED', 'NONE')
     or (r.referee_advantage_status = 'APPLIED' and r.referee_advantage_booking_id is distinct from b.id) then
    perform _referral_set_booking_discount(b.id, b.discount_cents - b.referral_advantage_cents, 0);
    return;
  end if;
  perform referral_sync_referee_advantage(r.id);
end;
$$;

-- Réservation créée directement (administration, autre parcours) pour un
-- filleul dont l'avantage était disponible.
create or replace function public.referral_booking_after_insert()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare v_ref uuid;
begin
  if NEW.referral_advantage_cents > 0 then
    select id into v_ref from referrals where referee_client_id = NEW.client_id;
    if v_ref is not null then
      begin
        perform referral_sync_referee_advantage(v_ref);
      exception when others then
        insert into referral_events (event, detail) values ('PROCESS_ERROR', jsonb_build_object('booking_id', NEW.id, 'error', SQLERRM, 'op', 'advantage_insert'));
      end;
    end if;
  end if;
  return null;
end;
$$;
create or replace trigger trg_referral_booking_after_insert
  after insert on public.bookings
  for each row execute function public.referral_booking_after_insert();

-- Réévaluation d'un filleul : récompense parrain + avantage filleul.
create or replace function public.referral_evaluate_for_client(p_client uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare v_id uuid; v_ref uuid;
begin
  if p_client is null then return; end if;
  for v_id, v_ref in
    select rw.id, rw.referral_id from referral_rewards rw
     where rw.referee_client_id = p_client
        or rw.referee_client_id = (select merged_into from clients where id = p_client)
  loop
    perform referral_evaluate_reward(v_id);
    perform referral_sync_referee_advantage(v_ref);
  end loop;
end;
$$;

-- Décision de l'admin : appliquer l'avantage sur une réservation précise
-- (y compris en cumul avec une autre réduction).
create or replace function public.admin_apply_referee_advantage(p_referral uuid, p_booking uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare r referrals%rowtype; b bookings%rowtype; v_amt int; v_gross int;
begin
  if not is_admin() then raise exception 'Accès réservé à l''administration.'; end if;
  select * into r from referrals where id = p_referral for update;
  if not found then raise exception 'Parrainage introuvable.'; end if;
  perform referral_sync_referee_advantage(r.id);
  select * into r from referrals where id = p_referral;
  if r.referee_advantage_status <> 'AVAILABLE' then raise exception 'L''avantage filleul n''est pas disponible (statut %).', r.referee_advantage_status; end if;
  select * into b from bookings where id = p_booking for update;
  if not found or b.client_id not in (select id from clients where id = r.referee_client_id or merged_into = r.referee_client_id) then
    raise exception 'Cette réservation n''appartient pas au filleul.';
  end if;
  if b.status not in ('PENDING', 'CONFIRMED', 'IN_PROGRESS', 'COMPLETED') then raise exception 'Réservation non modifiable (statut %).', b.status; end if;
  if exists (select 1 from invoices i join quotes q on q.id = i.quote_id where q.booking_id = b.id and i.status in ('ISSUED', 'PAID')) then
    raise exception 'Une facture a déjà été émise pour cette réservation : appliquez l''avantage sur la facture.';
  end if;
  v_gross := coalesce(b.service_price_cents, 0) + coalesce(b.travel_fee_cents, 0);
  v_amt := least(r.referee_advantage_cents, v_gross - coalesce(b.discount_cents, 0) - 100);
  if v_amt <= 0 then raise exception 'Montant de la réservation insuffisant pour appliquer l''avantage.'; end if;
  perform _referral_set_booking_discount(b.id, coalesce(b.discount_cents, 0) + v_amt, v_amt);
  insert into referral_events (referral_id, event, detail) values (r.id, 'ADMIN_ADVANTAGE_APPLIED', jsonb_build_object('booking_id', b.id, 'cents', v_amt, 'by', auth.uid()));
  return jsonb_build_object('ok', true, 'status', referral_sync_referee_advantage(r.id), 'cents', v_amt);
end;
$$;

-- Aperçu public avant réservation : code valide + avantage possible pour la
-- prestation choisie (sans rien révéler sur la personne).
create or replace function public.get_referral_booking_preview(p_code text, p_service_slug text default null, p_pack_slug text default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare s referral_settings%rowtype; v_code text := upper(regexp_replace(coalesce(p_code, ''), '\s', '', 'g'));
        v_price int; v_elig boolean;
begin
  select * into s from referral_settings where id;
  if not (s.is_enabled and s.booking_code_entry_enabled)
     or not exists (select 1 from referral_codes where code = v_code and status = 'active') then
    return jsonb_build_object('valid', false);
  end if;
  if s.referee_advantage_enabled and coalesce(s.referee_reward_cents, 0) > 0 and p_service_slug is not null then
    select coalesce(sv.referral_eligible, false), coalesce(pk.price_cents, sv.base_price_cents) into v_elig, v_price
      from services sv left join service_packs pk on pk.slug = p_pack_slug and pk.service_id = sv.id
     where sv.slug = p_service_slug and sv.is_active;
  end if;
  return jsonb_build_object('valid', true, 'code', v_code,
    'advantage_cents', case when coalesce(v_elig, false) and coalesce(v_price, 0) >= s.min_eligible_paid_cents then s.referee_reward_cents end);
end;
$$;

create or replace function public.get_my_referral_code()
returns text
language plpgsql
security definer
set search_path = public
as $$
declare v_client uuid; v_code text; s referral_settings%rowtype;
begin
  v_client := public.ensure_my_client();
  select code into v_code from referral_codes where client_id = v_client;
  if v_code is null then
    -- Nouveaux parrains : uniquement si le programme est publié et que les
    -- nouvelles inscriptions sont autorisées (Configuration).
    select * into s from referral_settings where id;
    if not (s.is_enabled and s.ambassador_public_enabled and s.manual_creation_enabled) then return null; end if;
    loop
      begin
        insert into referral_codes (client_id, code) values (v_client, public.generate_referral_code_for(v_client)) returning code into v_code;
        exit;
      exception when unique_violation then
        select code into v_code from referral_codes where client_id = v_client;
        exit when v_code is not null;
      end;
    end loop;
  end if;
  return v_code;
end;
$$;

create or replace function public.admin_update_referral_settings(p jsonb)
returns referral_settings
language plpgsql
security definer
set search_path = public
as $$
declare r referral_settings%rowtype; v_reward int := nullif(p->>'referrer_reward_cents', '')::int;
begin
  if not is_admin() then raise exception 'Accès réservé à l''administration.'; end if;
  if v_reward is not null and v_reward <= 0 then raise exception 'Récompense parrain invalide.'; end if;
  if nullif(p->>'referee_reward_cents', '')::int < 0 then raise exception 'Avantage filleul invalide.'; end if;
  update referral_settings set
    is_enabled = coalesce((p->>'is_enabled')::boolean, is_enabled),
    referee_reward_cents = coalesce(nullif(p->>'referee_reward_cents', '')::int, referee_reward_cents),
    referee_advantage_enabled = coalesce((p->>'referee_advantage_enabled')::boolean, referee_advantage_enabled),
    referrer_reward_cents = coalesce(v_reward, referrer_reward_cents),
    min_eligible_paid_cents = coalesce(nullif(p->>'min_eligible_paid_cents', '')::int, min_eligible_paid_cents),
    min_payout_cents = coalesce(nullif(p->>'min_payout_cents', '')::int, min_payout_cents),
    ambassador_public_enabled = coalesce((p->>'ambassador_public_enabled')::boolean, ambassador_public_enabled),
    individual_applications_public_enabled = coalesce((p->>'individual_applications_public_enabled')::boolean, individual_applications_public_enabled),
    business_program_public_enabled = coalesce((p->>'business_program_public_enabled')::boolean, business_program_public_enabled),
    payouts_enabled = coalesce((p->>'payouts_enabled')::boolean, payouts_enabled),
    booking_code_entry_enabled = coalesce((p->>'booking_code_entry_enabled')::boolean, booking_code_entry_enabled),
    manual_creation_enabled = coalesce((p->>'manual_creation_enabled')::boolean, manual_creation_enabled),
    reward_calculation_enabled = coalesce((p->>'reward_calculation_enabled')::boolean, reward_calculation_enabled),
    annual_tracking_threshold_cents = case when p ? 'annual_tracking_threshold_cents' then nullif((p->>'annual_tracking_threshold_cents')::int, 0) else annual_tracking_threshold_cents end,
    terms_validated = coalesce((p->>'terms_validated')::boolean, terms_validated),
    terms_validated_at = case when (p->>'terms_validated')::boolean is true and not terms_validated then now()
                              when (p->>'terms_validated')::boolean is false then null else terms_validated_at end,
    terms_validated_by = case when (p->>'terms_validated')::boolean is true and not terms_validated then auth.uid()
                              when (p->>'terms_validated')::boolean is false then null else terms_validated_by end,
    updated_at = now(), updated_by = auth.uid()
  where id returning * into r;
  if r.referee_advantage_enabled and r.min_eligible_paid_cents <= r.referee_reward_cents then
    raise exception 'Le montant minimum de prestation (%) doit être supérieur à l''avantage filleul (%).', referral_euros(r.min_eligible_paid_cents), referral_euros(r.referee_reward_cents);
  end if;
  if not r.terms_validated and (r.ambassador_public_enabled or r.individual_applications_public_enabled or r.business_program_public_enabled or r.payouts_enabled) then
    raise exception 'Conditions du programme À VALIDER : la publication, les demandes publiques et les versements restent désactivés tant qu''elles ne sont pas validées.';
  end if;
  if v_reward is not null then
    update referral_reward_rules set mode = 'fixed', fixed_cents = v_reward, percent_bp = null, is_active = true, updated_at = now(), updated_by = auth.uid()
     where scope_type = 'default';
    if not found then
      insert into referral_reward_rules (scope_type, mode, fixed_cents, is_active, updated_by) values ('default', 'fixed', v_reward, true, auth.uid());
    end if;
  end if;
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
    'referee_advantage_cents', case when s.referee_advantage_enabled and coalesce(s.referee_reward_cents, 0) > 0 then s.referee_reward_cents end,
    'reward_cents', (select fixed_cents from referral_reward_rules where scope_type = 'default' and is_active and mode = 'fixed'),
    'reward_rules_uniform', not exists (select 1 from referral_reward_rules where is_active and (scope_type <> 'default' or mode <> 'fixed')),
    'min_eligible_paid_cents', s.min_eligible_paid_cents,
    'min_payout_cents', s.min_payout_cents)
  from referral_settings s where s.id;
$$;

-- Étape complète du cycle de vie d'une récompense.
create or replace function public.referral_stage_v2(p_reward_id uuid)
returns text
language plpgsql
stable
security definer
set search_path = public
as $$
declare w referral_rewards%rowtype; b bookings%rowtype; v_pay record; v_payout text;
begin
  select * into w from referral_rewards where id = p_reward_id;
  if not found then return null; end if;
  select status into v_payout from referral_payout_requests where id = w.payout_id;
  if w.status = 'VALIDATED' and v_payout = 'PAID' then return 'RECOMPENSE_VERSEE'; end if;
  if w.status = 'VALIDATED' then return 'RECOMPENSE_ACQUISE'; end if;
  if w.status = 'REJECTED' then return 'REFUSE'; end if;
  if w.status = 'CANCELLED' then return 'ANNULE'; end if;
  select * into b from bookings where id = w.booking_id;
  if not found then return 'CODE_UTILISE'; end if;
  select * into v_pay from referral_booking_payment(b.id);
  if v_pay.has_paid or w.status_code in ('FLAGGED_PAID', 'CALCULATION_OFF', 'NO_REWARD_RULE') then return 'PAIEMENT_CONFIRME'; end if;
  if exists (select 1 from invoices i join quotes q on q.id = i.quote_id where q.booking_id = b.id and i.status = 'ISSUED') then return 'FACTURE_EMISE'; end if;
  if b.status = 'COMPLETED' then return 'INTERVENTION_REALISEE'; end if;
  if b.status in ('CONFIRMED', 'IN_PROGRESS') then return 'INTERVENTION_PLANIFIEE'; end if;
  if b.status = 'PENDING' then return 'RESERVATION'; end if;
  return 'CODE_UTILISE';
end;
$$;


-- Seuils de la récompense parrain appréciés sur le montant de la prestation
-- (payé + avantage filleul déduit) — remplacements vérifiés.
do $E$
declare d text; n text;
begin
  d := pg_get_functiondef('public.referral_evaluate_reward(uuid)'::regprocedure);
  n := replace(d, 'elsif v_pay.has_paid and v_pay.paid_net_cents < s.min_eligible_paid_cents then',
                  'elsif v_pay.has_paid and v_pay.paid_net_cents + referral_booking_advantage(w.booking_id) < s.min_eligible_paid_cents then');
  n := replace(n, 'if v_pay.has_paid and v_pay.paid_net_cents >= s.min_eligible_paid_cents then',
                  'if v_pay.has_paid and v_pay.paid_net_cents + referral_booking_advantage(bk.id) >= s.min_eligible_paid_cents then');
  if position('referral_booking_advantage(w.booking_id)' in n) = 0 or position('referral_booking_advantage(bk.id)' in n) = 0 then
    raise exception 'Remplacement impossible : referral_evaluate_reward';
  end if;
  execute n;

  d := pg_get_functiondef('public.admin_confirm_payment_and_validate(uuid,integer,text,date,text,text)'::regprocedure);
  n := replace(d, E'  if coalesce(p_paid_cents, 0) < s.min_eligible_paid_cents then\n    raise exception ''Montant payé inférieur au seuil de % : aucune récompense.'', referral_euros(s.min_eligible_paid_cents);\n  end if;',
                  E'  if coalesce(p_paid_cents, 0) <= 0 then raise exception ''Montant payé requis.''; end if;');
  n := replace(n, E'  if p_payment_date < b.date - 30 then',
                  E'  if p_paid_cents + referral_booking_advantage(v_booking) < s.min_eligible_paid_cents then\n    raise exception ''Montant de la prestation inférieur au seuil de % : aucune récompense.'', referral_euros(s.min_eligible_paid_cents);\n  end if;\n  if p_payment_date < b.date - 30 then');
  if position('Montant payé requis' in n) = 0 or position('referral_booking_advantage(v_booking)' in n) = 0 then
    raise exception 'Remplacement impossible : admin_confirm_payment_and_validate';
  end if;
  execute n;
end $E$;

-- ---------------------------------------------------------------------
-- Modifications ciblées de fonctions existantes (remplacements vérifiés).
-- ---------------------------------------------------------------------
do $M$
declare d text; n text; sig text;
begin
  -- 1) Réservations : code transmis au trigger d'avantage, puis rattachement.
  foreach sig in array array[
    'public.create_guest_or_quote_booking(text,date,time without time zone,text,text,text,text,text,text,text,text,boolean,boolean,text)',
    'public.create_booking(text,date,time without time zone,text,uuid,uuid,text,text,text,boolean,boolean,text)'] loop
    d := pg_get_functiondef(sig::regprocedure);
    n := replace(d, E'  begin\n    insert into bookings (',
                    E'  perform set_config(''app.referral_code'', coalesce(p_referral_code, ''''), true);\n  begin\n    insert into bookings (');
    n := replace(n, E'  return query select v_booking_id, v_reference, v_total_cents;',
                    E'  perform set_config(''app.referral_code'', '''', true);\n  begin\n    perform public.referral_reconcile_booking_advantage(v_booking_id);\n  exception when others then\n    insert into referral_events (event, detail) values (''PROCESS_ERROR'', jsonb_build_object(''booking_id'', v_booking_id, ''error'', SQLERRM, ''op'', ''advantage_reconcile''));\n  end;\n  select bk.total_cents into v_total_cents from bookings bk where bk.id = v_booking_id;\n  return query select v_booking_id, v_reference, v_total_cents;');
    if position('app.referral_code'', coalesce(p_referral_code' in n) = 0 or position('advantage_reconcile' in n) = 0 then
      raise exception 'Remplacement impossible dans %', sig;
    end if;
    execute n;
  end loop;

  -- 2) Plus de crédit cagnotte après validation : l'avantage filleul est la
  --    réduction de sa 1re prestation.
  d := pg_get_functiondef('public._referral_after_validation(uuid)'::regprocedure);
  n := replace(d, E'  v_ree := coalesce(s.referee_reward_cents, 0);', E'  v_ree := 0; -- avantage filleul = réduction de la 1re prestation (plus de crédit cagnotte)');
  n := replace(n, E'referee_reward_cents = v_ree,', E'referee_reward_cents = coalesce(referee_advantage_cents, 0),');
  if n = d or position('v_ree := 0;' in n) = 0 or position('coalesce(referee_advantage_cents, 0)' in n) = 0 then raise exception 'Remplacement impossible : _referral_after_validation'; end if;
  execute n;

  -- 3) Refus / annulation par l'admin : avantage filleul synchronisé.
  d := pg_get_functiondef('public.admin_reject_referral_reward(uuid,text)'::regprocedure);
  n := replace(d, E'  return ''REJECTED'';\nend;', E'  perform referral_sync_referee_advantage(w.referral_id);\n  return ''REJECTED'';\nend;');
  if n = d then raise exception 'Remplacement impossible : admin_reject_referral_reward'; end if;
  execute n;

  -- 4) Acceptation d'une demande : soumise à « Nouveaux parrains autorisés ».
  d := pg_get_functiondef('public.admin_set_business_application_status(uuid,text,text)'::regprocedure);
  n := replace(d, E'    if exists (select 1 from referral_codes where client_id = v_client) then\n      update referral_codes set participant_type = a.applicant_type',
                  E'    if not exists (select 1 from referral_codes where client_id = v_client) and not (select manual_creation_enabled from referral_settings where id) then\n      raise exception ''Nouveaux parrains non autorisés (Parrainages > Configuration).'';\n    end if;\n    if exists (select 1 from referral_codes where client_id = v_client) then\n      update referral_codes set participant_type = a.applicant_type');
  if n = d then raise exception 'Remplacement impossible : admin_set_business_application_status'; end if;
  execute n;

  -- 5) Fiche parrain : cycle complet et traçabilité.
  d := pg_get_functiondef('public.admin_ambassador_detail(uuid)'::regprocedure);
  n := replace(d, E'''stage'', referral_stage(w.status, w.status_code, b.status, p.status),',
    E'''stage'', referral_stage_v2(w.id), ''referral_id'', rf.id, ''code_used_at'', rf.attributed_at,\n               ''invoice'', (select jsonb_build_object(''reference'', i.reference, ''status'', i.status, ''total_cents'', i.total_cents, ''refunded_cents'', i.refunded_cents, ''paid_at'', i.paid_at)\n                             from invoices i join quotes q on q.id = i.quote_id where q.booking_id = b.id order by (i.status = ''PAID'') desc, i.created_at desc limit 1),\n               ''advantage_cents'', rf.referee_advantage_cents, ''advantage_status'', rf.referee_advantage_status, ''advantage_booking_ref'', (select reference from bookings where id = rf.referee_advantage_booking_id),\n               ''advantage_applied_cents'', b.referral_advantage_cents,\n               ''referee_open_bookings'', (select jsonb_agg(jsonb_build_object(''id'', x.id, ''reference'', x.reference, ''date'', x.date, ''status'', x.status) order by x.date) from bookings x where x.client_id = w.referee_client_id and x.status in (''PENDING'', ''CONFIRMED'', ''IN_PROGRESS'', ''COMPLETED'')),');
  if n = d then raise exception 'Remplacement impossible : admin_ambassador_detail'; end if;
  execute n;

  -- 6) Coût du programme : récompenses + avantages filleul utilisés.
  d := pg_get_functiondef('public.admin_referral_dashboard()'::regprocedure);
  n := replace(d, E'''program_cost_cents'', coalesce((select sum(amount_cents) from referral_rewards where status = ''VALIDATED''), 0)',
    E'''advantages_used_cents'', coalesce((select sum(referee_advantage_cents) from referrals where referee_advantage_status = ''USED''), 0),\n    ''advantages_applied_count'', (select count(*) from referrals where referee_advantage_status = ''APPLIED''),\n    ''program_cost_cents'', coalesce((select sum(amount_cents) from referral_rewards where status = ''VALIDATED''), 0)\n                          + coalesce((select sum(referee_advantage_cents) from referrals where referee_advantage_status = ''USED''), 0)');
  if n = d then raise exception 'Remplacement impossible : admin_referral_dashboard'; end if;
  execute n;

  -- 7) Espace client du filleul : état de son avantage.
  d := pg_get_functiondef('public.get_my_ambassador()'::regprocedure);
  n := replace(d, E'''invited_by'', (select jsonb_build_object(''status'', status) from referrals where referee_client_id = v_client)',
    E'''invited_by'', (select jsonb_build_object(''status'', status, ''advantage_cents'', referee_advantage_cents, ''advantage_status'', referee_advantage_status) from referrals where referee_client_id = v_client)');
  if n = d then raise exception 'Remplacement impossible : get_my_ambassador'; end if;
  execute n;
end $M$;

-- Parrainages existants : avantage initialisé (aucun rendez-vous existant
-- n'est modifié ; l'admin peut l'appliquer depuis la fiche du parrain).
do $B$ declare v uuid; begin
  for v in select id from referrals where referee_advantage_status is null loop
    perform referral_sync_referee_advantage(v);
  end loop;
end $B$;

revoke all on function public.referral_booking_advantage(uuid) from public, anon, authenticated;
revoke all on function public._referral_set_booking_discount(uuid, integer, integer) from public, anon, authenticated;
revoke all on function public.referral_code_check(uuid, text) from public, anon, authenticated;
revoke all on function public.referral_booking_advantage_on_insert() from public, anon, authenticated;
revoke all on function public.referral_sync_referee_advantage(uuid) from public, anon, authenticated;
revoke all on function public.referral_reconcile_booking_advantage(uuid) from public, anon, authenticated;
revoke all on function public.referral_booking_after_insert() from public, anon, authenticated;
revoke all on function public.referral_stage_v2(uuid) from public, anon, authenticated;
revoke all on function public.admin_apply_referee_advantage(uuid, uuid) from public, anon;
grant execute on function public.admin_apply_referee_advantage(uuid, uuid) to authenticated;
grant execute on function public.get_referral_booking_preview(text, text, text) to anon, authenticated;
