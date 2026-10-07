-- PARRAINAGE HAYEVA — finalisation :
--   * récompenses CONFIGURABLES (montant fixe ou pourcentage, par
--     prestation / catégorie / toutes prestations) — referral_reward_rules ;
--   * historique des codes (un ancien code n'attribue plus rien et ne peut
--     jamais être réattribué à quelqu'un d'autre) — referral_code_history ;
--   * interrupteurs séparés (saisie des codes à la réservation, création
--     manuelle, calcul des récompenses) ;
--   * « MARQUER COMME PAYÉ » (règlement manuel, sans virement automatique) ;
--   * administration enrichie (refusés, généré, payé, reste à payer,
--     historique détaillé).
-- Tout ce qui existe est conservé (registre, idempotence, RLS, anti-fraude).
-- Aucune suppression de données.

-- 1) Interrupteurs
alter table public.referral_settings
  add column if not exists booking_code_entry_enabled boolean not null default true,
  add column if not exists manual_creation_enabled boolean not null default true,
  add column if not exists reward_calculation_enabled boolean not null default true;

-- 2) Règles de récompense (priorité : prestation > catégorie > toutes)
create table if not exists public.referral_reward_rules (
  id uuid primary key default gen_random_uuid(),
  scope_type text not null check (scope_type in ('default', 'category', 'service')),
  scope_value text,
  label text,
  mode text not null check (mode in ('fixed', 'percent')),
  fixed_cents integer check (fixed_cents is null or fixed_cents > 0),
  percent_bp integer check (percent_bp is null or (percent_bp > 0 and percent_bp <= 10000)),
  max_cents integer check (max_cents is null or max_cents > 0),
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  updated_by uuid,
  check ((scope_type = 'default') = (scope_value is null)),
  check ((mode = 'fixed' and fixed_cents is not null) or (mode = 'percent' and percent_bp is not null))
);
create unique index if not exists referral_reward_rules_scope_uidx on public.referral_reward_rules (scope_type, coalesce(scope_value, ''));
alter table public.referral_reward_rules enable row level security;
create policy referral_reward_rules_admin_select on public.referral_reward_rules for select to authenticated using (is_admin());
revoke all on public.referral_reward_rules from anon, authenticated;
grant select on public.referral_reward_rules to authenticated;
-- Valeur actuelle du programme (20 € fixe, toutes prestations) reprise telle quelle.
insert into public.referral_reward_rules (scope_type, scope_value, label, mode, fixed_cents)
select 'default', null, 'Toutes prestations', 'fixed', s.referrer_reward_cents
  from public.referral_settings s where s.id and s.referrer_reward_cents > 0
on conflict do nothing;

-- 3) Historique des codes
create table if not exists public.referral_code_history (
  id uuid primary key default gen_random_uuid(),
  client_id uuid not null references public.clients(id),
  code text not null unique,
  retired_at timestamptz not null default now(),
  retired_by uuid
);
alter table public.referral_code_history enable row level security;
create policy referral_code_history_admin_select on public.referral_code_history for select to authenticated using (is_admin());
revoke all on public.referral_code_history from anon, authenticated;
grant select on public.referral_code_history to authenticated;

-- 4) Montant connu / à calculer (pourcentage sans montant connu)
alter table public.referral_rewards add column if not exists amount_known boolean not null default true;

-- ---------------------------------------------------------------------
-- 5) Fonctions de calcul
-- ---------------------------------------------------------------------
create or replace function public.referral_rule_for_booking(p_booking_id uuid)
returns public.referral_reward_rules
language plpgsql
stable
security definer
set search_path = public
as $$
declare r referral_reward_rules%rowtype; v_slug text; v_cat text;
begin
  if p_booking_id is not null then
    select sv.slug, sv.category into v_slug, v_cat from bookings b join services sv on sv.id = b.service_id where b.id = p_booking_id;
  end if;
  select * into r from referral_reward_rules
   where is_active and ((scope_type = 'service' and scope_value = v_slug) or (scope_type = 'category' and scope_value = v_cat) or scope_type = 'default')
   order by case scope_type when 'service' then 1 when 'category' then 2 else 3 end
   limit 1;
  return r;
end;
$$;

-- Récompense pour un montant d'intervention donné (centimes entiers).
create or replace function public.referral_compute_reward(p_booking_id uuid, p_amount_cents integer)
returns integer
language plpgsql
stable
security definer
set search_path = public
as $$
declare r referral_reward_rules%rowtype; v bigint;
begin
  r := referral_rule_for_booking(p_booking_id);
  if r.id is null then return 0; end if;
  if r.mode = 'fixed' then
    v := r.fixed_cents;
  else
    v := (greatest(coalesce(p_amount_cents, 0), 0)::bigint * r.percent_bp + 5000) / 10000;
  end if;
  if r.max_cents is not null then v := least(v, r.max_cents); end if;
  return greatest(v, 0)::int;
end;
$$;

-- Estimation (avant paiement) : sur le montant prévu de la réservation.
create or replace function public.referral_estimate_reward(p_booking_id uuid)
returns integer
language sql
stable
security definer
set search_path = public
as $$
  select referral_compute_reward(p_booking_id, (select total_cents from bookings where id = p_booking_id));
$$;

-- Un code est-il déjà pris (actif, ancien code, ou utilisé dans l'historique) ?
create or replace function public.referral_code_taken(p_code text, p_client uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (select 1 from referral_codes where code = p_code and client_id is distinct from p_client)
      or exists (select 1 from referral_code_history where code = p_code and client_id is distinct from p_client)
      or exists (select 1 from referrals where code_used = p_code and referrer_client_id is distinct from p_client);
$$;

create or replace function public.referral_balances(p_client uuid)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object(
    'pending_cents', coalesce((select sum(amount_cents) from referral_rewards where referrer_client_id = p_client and status in ('PENDING', 'REVIEW') and amount_known), 0),
    'pending_unknown_count', (select count(*) from referral_rewards where referrer_client_id = p_client and status in ('PENDING', 'REVIEW') and not amount_known),
    'available_cents', coalesce((select sum(amount_cents) from referral_rewards where referrer_client_id = p_client and status = 'VALIDATED' and payout_id is null and not clawback_alert), 0),
    'reserved_cents', coalesce((select sum(amount_cents) from referral_payout_requests where referrer_client_id = p_client and status in ('REQUESTED', 'REVIEWING', 'APPROVED')), 0),
    'paid_cents', coalesce((select sum(amount_cents) from referral_payout_requests where referrer_client_id = p_client and status = 'PAID'), 0),
    'generated_cents', coalesce((select sum(amount_cents) from referral_rewards where referrer_client_id = p_client and status = 'VALIDATED'), 0),
    'remaining_cents', coalesce((select sum(w.amount_cents) from referral_rewards w left join referral_payout_requests p on p.id = w.payout_id
                                  where w.referrer_client_id = p_client and w.status = 'VALIDATED' and not w.clawback_alert and (p.id is null or p.status <> 'PAID')), 0),
    'clients_count', (select count(*) from referral_rewards where referrer_client_id = p_client),
    'validated_count', (select count(*) from referral_rewards where referrer_client_id = p_client and status = 'VALIDATED'),
    'pending_count', (select count(*) from referral_rewards where referrer_client_id = p_client and status in ('PENDING', 'REVIEW')),
    'rejected_count', (select count(*) from referral_rewards where referrer_client_id = p_client and status in ('REJECTED', 'CANCELLED'))
  );
$$;

-- ---------------------------------------------------------------------
-- 6) Évaluation d'une prime (reprend 0082 ; montant calculé par les règles)
-- ---------------------------------------------------------------------
create or replace function public.referral_evaluate_reward(p_reward_id uuid)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  w referral_rewards%rowtype; r referrals%rowtype; s referral_settings%rowtype;
  ref_c clients%rowtype; ree_c clients%rowtype;
  v_ids uuid[]; v_flags text[]; v_status text; v_code text; v_reason text;
  v_booking uuid; v_paid int; v_pay record; bk record;
  v_awaiting uuid; v_below uuid; v_below_paid int; v_active int; v_cancelled int; v_noshow int;
  v_ins int; v_old_status text; v_old_code text; v_final int; v_est int;
begin
  select * into w from referral_rewards where id = p_reward_id for update;
  if not found then return 'NOT_FOUND'; end if;
  select * into s from referral_settings where id;
  select * into r from referrals where id = w.referral_id;
  v_old_status := w.status; v_old_code := w.status_code;

  if w.status = 'VALIDATED' then
    select * into v_pay from referral_booking_payment(w.booking_id);
    if v_pay.has_paid and v_pay.paid_net_cents < s.min_eligible_paid_cents then
      if w.payout_id is not null and _referral_detach_from_payout(w.id, 'Intervention remboursée') = 'PAID' then
        if not w.clawback_alert then
          update referral_rewards set clawback_alert = true,
                 status_reason = 'Récompense déjà versée — intervention remboursée — vérification requise', updated_at = now()
           where id = w.id;
          insert into referral_ledger (referrer_client_id, reward_id, payout_id, entry_type, amount_cents, detail)
          values (w.referrer_client_id, w.id, w.payout_id, 'reward_clawback_alert', 0, jsonb_build_object('paid_net_cents', v_pay.paid_net_cents))
          on conflict do nothing;
          perform admin_notify('payment', 'Parrainage — vérification requise',
            'Récompense déjà versée — intervention remboursée — vérification requise', w.booking_id, 'referral-clawback:' || w.id, true);
        end if;
        return 'CLAWBACK_ALERT';
      end if;
      update referral_rewards set status = 'CANCELLED', status_code = 'REFUNDED', status_reason = 'Intervention remboursée avant versement',
             cancelled_at = now(), paid_amount_cents = v_pay.paid_net_cents, updated_at = now()
       where id = w.id;
      insert into referral_ledger (referrer_client_id, reward_id, entry_type, amount_cents, detail)
      values (w.referrer_client_id, w.id, 'reward_cancelled', -w.amount_cents, jsonb_build_object('reason', 'refund', 'paid_net_cents', v_pay.paid_net_cents))
      on conflict do nothing;
      update referrals set status = 'INELIGIBLE', status_reason = 'Intervention remboursée', updated_at = now() where id = w.referral_id;
      insert into referral_events (referral_id, event, detail) values (w.referral_id, 'REWARD_CANCELLED_REFUND', jsonb_build_object('reward_id', w.id));
      perform admin_notify('payment', 'Prime de parrainage annulée', 'Intervention remboursée avant versement : prime annulée.', w.booking_id, 'referral-refund:' || w.id, false);
      return 'CANCELLED_REFUND';
    end if;
    return 'VALIDATED';
  end if;

  if w.status_code like 'ADMIN_%' or w.status_code = 'REFUNDED' then
    return 'FINAL_' || w.status;
  end if;
  if not s.is_enabled then
    return 'DISABLED';
  end if;

  select * into ref_c from clients where id = w.referrer_client_id;
  select * into ree_c from clients where id = w.referee_client_id;
  select array_agg(id) into v_ids from clients where id = w.referee_client_id or merged_into = w.referee_client_id;
  v_flags := array(select f from unnest(w.review_flags) f where f in ('MULTI_CODE_ATTEMPT', 'ADMIN_FLAG'));

  if (ref_c.user_id is not null and ref_c.user_id = ree_c.user_id)
     or (nullif(lower(trim(ref_c.email)), '') is not null and lower(trim(ref_c.email)) = lower(trim(coalesce(ree_c.email, ''))))
     or (nullif(regexp_replace(coalesce(ref_c.phone, ''), '[^0-9]', '', 'g'), '') is not null
         and right(regexp_replace(coalesce(ref_c.phone, ''), '[^0-9]', '', 'g'), 9) = right(regexp_replace(coalesce(ree_c.phone, ''), '[^0-9]', '', 'g'), 9))
     or exists (select 1 from clients c where c.id = w.referee_client_id and c.merged_into = w.referrer_client_id)
  then
    v_status := 'REJECTED'; v_code := 'SELF_REFERRAL'; v_reason := 'Auto-parrainage (mêmes identifiants que le parrain)';
  elsif exists (select 1 from bookings x where x.client_id = any(v_ids) and x.status = 'COMPLETED' and x.created_at < r.attributed_at - interval '5 minutes')
     or exists (select 1 from invoices i where i.client_id = any(v_ids) and i.status = 'PAID' and i.created_at < r.attributed_at)
  then
    v_status := 'REJECTED'; v_code := 'EXISTING_CLIENT'; v_reason := 'Client déjà existant avant le parrainage';
  else
    if nullif(lower(regexp_replace(coalesce(ref_c.address, ''), '[^a-z0-9]', '', 'gi')), '') is not null
       and lower(regexp_replace(coalesce(ref_c.address, ''), '[^a-z0-9]', '', 'gi')) = lower(regexp_replace(coalesce(ree_c.address, ''), '[^a-z0-9]', '', 'gi')) then
      v_flags := array_append(v_flags, 'SAME_ADDRESS');
    end if;
    if exists (select 1 from bookings x where x.client_id = any(v_ids) and x.created_at < r.attributed_at - interval '1 hour' and x.status <> 'COMPLETED')
       or exists (select 1 from quotes q where q.client_id = any(v_ids) and q.created_at < r.attributed_at - interval '1 hour') then
      v_flags := array_append(v_flags, 'PRIOR_ACTIVITY');
    end if;
    if exists (select 1 from clients c2 join bookings x on x.client_id = c2.id
               where c2.id <> all(v_ids) and c2.merged_into is null and x.status = 'COMPLETED'
                 and ((nullif(lower(trim(ree_c.email)), '') is not null and lower(trim(c2.email)) = lower(trim(ree_c.email)))
                   or (nullif(regexp_replace(coalesce(ree_c.phone, ''), '[^0-9]', '', 'g'), '') is not null
                       and right(regexp_replace(coalesce(c2.phone, ''), '[^0-9]', '', 'g'), 9) = right(regexp_replace(coalesce(ree_c.phone, ''), '[^0-9]', '', 'g'), 9)))) then
      v_flags := array_append(v_flags, 'POSSIBLE_EXISTING_CLIENT');
    end if;
    if (select count(*) from bookings x where x.client_id = any(v_ids) and x.status in ('CANCELLED', 'NO_SHOW')) >= 3 then
      v_flags := array_append(v_flags, 'MANY_CANCELLATIONS');
    end if;
    if (select count(*) from referrals x where x.referrer_client_id = w.referrer_client_id
          and x.created_at between r.created_at - interval '24 hours' and r.created_at + interval '24 hours') >= 5 then
      v_flags := array_append(v_flags, 'REFERRER_BURST');
    end if;

    v_booking := null;
    for bk in
      select x.id, x.created_at from bookings x join services sv on sv.id = x.service_id
       where x.client_id = any(v_ids) and x.status = 'COMPLETED' and coalesce(sv.referral_eligible, false)
       order by x.date, x.start_time, x.created_at
    loop
      select * into v_pay from referral_booking_payment(bk.id);
      if v_pay.has_paid and v_pay.paid_net_cents >= s.min_eligible_paid_cents then
        v_booking := bk.id; v_paid := v_pay.paid_net_cents;
        if v_pay.foreign_client then v_flags := array_append(v_flags, 'PAYMENT_MISMATCH'); end if;
        if bk.created_at < r.attributed_at - interval '1 hour' then v_flags := array_append(v_flags, 'CODE_AFTER_BOOKING'); end if;
        exit;
      elsif not v_pay.has_paid and v_awaiting is null then
        v_awaiting := bk.id;
      elsif v_pay.has_paid and v_below is null then
        v_below := bk.id; v_below_paid := v_pay.paid_net_cents;
      end if;
    end loop;

    select count(*) filter (where x.status in ('PENDING', 'CONFIRMED', 'IN_PROGRESS')),
           count(*) filter (where x.status = 'CANCELLED'),
           count(*) filter (where x.status = 'NO_SHOW')
      into v_active, v_cancelled, v_noshow
      from bookings x where x.client_id = any(v_ids);

    if v_booking is not null then
      v_status := 'VALIDATED'; v_code := 'PAID_ELIGIBLE'; v_reason := null;
    elsif v_awaiting is not null then
      v_status := 'PENDING'; v_code := 'AWAITING_PAYMENT'; v_booking := v_awaiting;
      v_reason := 'Intervention terminée — paiement non confirmé : à valider par l''administrateur';
    elsif v_active > 0 then
      v_status := 'PENDING'; v_code := 'BOOKED'; v_reason := 'Intervention prévue';
      select x.id into v_booking from bookings x where x.client_id = any(v_ids) and x.status in ('PENDING', 'CONFIRMED', 'IN_PROGRESS') order by x.date, x.start_time limit 1;
    elsif v_below is not null then
      v_status := 'REJECTED'; v_code := 'BELOW_MIN'; v_booking := v_below; v_paid := v_below_paid;
      v_reason := 'Montant payé (' || referral_euros(v_below_paid) || ') inférieur au seuil de ' || referral_euros(s.min_eligible_paid_cents);
    elsif v_noshow > 0 and v_cancelled = 0 then
      v_status := 'CANCELLED'; v_code := 'NO_SHOW'; v_reason := 'Client absent';
    elsif v_cancelled > 0 or v_noshow > 0 then
      v_status := 'CANCELLED'; v_code := 'BOOKING_CANCELLED'; v_reason := 'Rendez-vous annulé';
    else
      v_status := 'PENDING'; v_code := 'NO_BOOKING'; v_reason := 'En attente de réservation';
    end if;

    -- Montant : calculé par les règles configurées (jamais en dur).
    if v_status = 'VALIDATED' then
      v_final := referral_compute_reward(v_booking, v_paid);
      if not s.reward_calculation_enabled then
        v_status := 'PENDING'; v_code := 'CALCULATION_OFF'; v_reason := 'Paiement confirmé — calcul des récompenses désactivé : validation par l''administrateur';
      elsif v_final <= 0 then
        v_status := 'REVIEW'; v_code := 'NO_REWARD_RULE'; v_reason := 'Paiement confirmé — aucune règle de récompense configurée pour cette prestation';
      end if;
    end if;

    if array_length(v_flags, 1) > 0 and v_status in ('PENDING', 'VALIDATED') then
      if v_status = 'VALIDATED' then v_code := 'FLAGGED_PAID'; v_reason := 'Paiement confirmé — à vérifier avant validation';
      end if;
      v_status := 'REVIEW';
    end if;
  end if;

  v_flags := array(select distinct f from unnest(v_flags) f order by 1);

  if v_status = 'VALIDATED' then
    insert into referral_ledger (referrer_client_id, reward_id, entry_type, amount_cents, detail)
    values (w.referrer_client_id, w.id, 'reward_validated', v_final,
            jsonb_build_object('booking_id', v_booking, 'paid_amount_cents', v_paid, 'source', 'auto_invoice'))
    on conflict do nothing;
    get diagnostics v_ins = row_count;
    if v_ins = 0 then return 'ALREADY_VALIDATED'; end if;
    update referral_rewards set status = 'VALIDATED', status_code = v_code, status_reason = null, review_flags = v_flags,
           booking_id = v_booking, paid_amount_cents = v_paid, validation_source = 'auto_invoice',
           amount_cents = v_final, amount_known = true, validated_at = now(), updated_at = now()
     where id = w.id;
    perform _referral_after_validation(w.id);
    return 'VALIDATED';
  end if;

  -- Montant indicatif tant que la prime n'est pas validée.
  v_est := case when v_paid is not null and v_status = 'REVIEW' then referral_compute_reward(v_booking, v_paid) else referral_estimate_reward(v_booking) end;
  if coalesce(v_est, 0) > 0 and (v_est <> w.amount_cents or not w.amount_known) then
    update referral_rewards set amount_cents = v_est, amount_known = true, updated_at = now() where id = w.id;
  elsif coalesce(v_est, 0) <= 0 and w.amount_known then
    update referral_rewards set amount_known = false, updated_at = now() where id = w.id;
  end if;

  if v_status is distinct from w.status or v_code is distinct from w.status_code or v_flags is distinct from w.review_flags
     or v_booking is distinct from w.booking_id or v_reason is distinct from w.status_reason then
    update referral_rewards set status = v_status, status_code = v_code, status_reason = v_reason, review_flags = v_flags,
           booking_id = v_booking, paid_amount_cents = case when v_code in ('BELOW_MIN', 'FLAGGED_PAID', 'CALCULATION_OFF', 'NO_REWARD_RULE') then v_paid else paid_amount_cents end,
           cancelled_at = case when v_status = 'CANCELLED' then coalesce(cancelled_at, now()) else null end,
           updated_at = now()
     where id = w.id;
    insert into referral_events (referral_id, event, detail)
    values (w.referral_id, 'REWARD_' || v_status, jsonb_build_object('reward_id', w.id, 'code', v_code, 'from', v_old_status || '/' || v_old_code, 'flags', v_flags));
    update referrals set status = case when v_code in ('SELF_REFERRAL', 'EXISTING_CLIENT') then 'INELIGIBLE' else 'PENDING' end,
           status_reason = v_reason, updated_at = now()
     where id = w.referral_id and status <> 'VALIDATED';
    if v_status = 'REVIEW' and v_old_status <> 'REVIEW' then
      perform admin_notify('payment', 'Parrainage à vérifier', 'Un parrainage nécessite une vérification' || case when array_length(v_flags, 1) > 0 then ' (' || array_to_string(v_flags, ', ') || ')' else '' end || '.',
        v_booking, 'referral-review:' || w.id || ':' || v_code || ':' || array_to_string(v_flags, ','), true);
    elsif v_code in ('AWAITING_PAYMENT', 'CALCULATION_OFF') and v_old_code is distinct from v_code then
      perform admin_notify('payment', 'Parrainage à valider', 'Intervention terminée d''un filleul : vérifiez le paiement pour valider la récompense.',
        v_booking, 'referral-awaiting:' || w.id || ':' || v_booking || ':' || v_code, false);
    end if;
  end if;
  return v_status || '/' || v_code;
end;
$$;

-- ---------------------------------------------------------------------
-- 7) Attribution : interrupteur « saisie des codes », montant estimé
-- ---------------------------------------------------------------------
create or replace function public.get_referral_preview(p_code text)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare s referral_settings%rowtype; v_ok boolean;
begin
  select * into s from referral_settings where id;
  select exists (select 1 from referral_codes where code = upper(regexp_replace(coalesce(p_code, ''), '\s', '', 'g')) and status = 'active') into v_ok;
  if not v_ok or not s.is_enabled or not s.booking_code_entry_enabled then return jsonb_build_object('valid', false); end if;
  return jsonb_build_object('valid', true);
end;
$$;

create or replace function public._attach_referral(p_referee uuid, p_code text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_code text := upper(regexp_replace(coalesce(p_code, ''), '\s', '', 'g'));
  v_referrer uuid; ref_c clients%rowtype; ree_c clients%rowtype; v_existing referrals%rowtype; v_new uuid; v_reward uuid;
  s referral_settings%rowtype; v_booking uuid; v_est int;
begin
  select * into s from referral_settings where id;
  if not s.is_enabled then return jsonb_build_object('ok', false, 'error', 'PROGRAMME_INACTIF'); end if;
  if not s.booking_code_entry_enabled then return jsonb_build_object('ok', false, 'error', 'SAISIE_DESACTIVEE'); end if;
  select client_id into v_referrer from referral_codes where code = v_code and status = 'active';
  if v_referrer is null then
    if exists (select 1 from referral_code_history where code = v_code) or exists (select 1 from referral_codes where code = v_code) then
      insert into referral_events (event, detail) values ('INACTIVE_CODE_ATTEMPT', jsonb_build_object('code', v_code, 'referee', p_referee));
    end if;
    return jsonb_build_object('ok', false, 'error', 'CODE_INVALIDE');
  end if;
  select * into ref_c from clients where id = v_referrer;
  select * into ree_c from clients where id = p_referee;
  if v_referrer = p_referee
     or (ref_c.user_id is not null and ref_c.user_id = ree_c.user_id)
     or (nullif(lower(trim(ref_c.email)), '') is not null and lower(trim(ref_c.email)) = lower(trim(ree_c.email)))
     or (nullif(regexp_replace(coalesce(ref_c.phone, ''), '[^0-9]', '', 'g'), '') is not null
         and right(regexp_replace(coalesce(ref_c.phone, ''), '[^0-9]', '', 'g'), 9) = right(regexp_replace(coalesce(ree_c.phone, ''), '[^0-9]', '', 'g'), 9))
  then
    insert into referral_events (event, detail) values ('SELF_REFERRAL_ATTEMPT', jsonb_build_object('referrer', v_referrer, 'referee', p_referee));
    return jsonb_build_object('ok', false, 'error', 'AUTO_PARRAINAGE');
  end if;

  select * into v_existing from referrals where referee_client_id = p_referee;
  if found then
    if v_existing.referrer_client_id = v_referrer then return jsonb_build_object('ok', true, 'already', true, 'status', v_existing.status); end if;
    insert into referral_events (referral_id, event, detail)
    values (v_existing.id, 'ATTACH_CONFLICT', jsonb_build_object('attempted_code', v_code));
    update referral_rewards set review_flags = array(select distinct f from unnest(review_flags || array['MULTI_CODE_ATTEMPT']) f), updated_at = now()
     where referral_id = v_existing.id and status in ('PENDING', 'REVIEW') and not ('MULTI_CODE_ATTEMPT' = any(review_flags));
    perform referral_evaluate_for_client(p_referee);
    return jsonb_build_object('ok', false, 'error', 'DEJA_PARRAINE');
  end if;
  if exists (select 1 from referrals where referee_client_id = v_referrer and referrer_client_id = p_referee) then
    return jsonb_build_object('ok', false, 'error', 'PARRAINAGE_CIRCULAIRE');
  end if;
  if exists (select 1 from bookings where client_id = p_referee and status = 'COMPLETED')
     or exists (select 1 from invoices where client_id = p_referee and status = 'PAID') then
    return jsonb_build_object('ok', false, 'error', 'CLIENT_DEJA_EXISTANT');
  end if;

  insert into referrals (referrer_client_id, referee_client_id, code_used, status_reason)
  values (v_referrer, p_referee, v_code, 'En attente de la première intervention éligible terminée')
  on conflict (referee_client_id) do nothing returning id into v_new;
  if v_new is null then return jsonb_build_object('ok', true, 'already', true); end if;
  select id into v_booking from bookings where client_id = p_referee and status in ('PENDING', 'CONFIRMED', 'IN_PROGRESS') order by created_at desc limit 1;
  insert into referral_events (referral_id, event, detail)
  values (v_new, 'ATTACHED', jsonb_build_object('code', v_code, 'booking_id', v_booking,
          'service', (select sv.slug from bookings b join services sv on sv.id = b.service_id where b.id = v_booking)));

  v_est := referral_estimate_reward(v_booking);
  insert into referral_rewards (referral_id, referrer_client_id, referee_client_id, booking_id, amount_cents, amount_known)
  values (v_new, v_referrer, p_referee, v_booking, greatest(coalesce(v_est, 0), 1), coalesce(v_est, 0) > 0)
  on conflict (referral_id) do nothing returning id into v_reward;
  if v_reward is not null then
    insert into referral_ledger (referrer_client_id, reward_id, entry_type, amount_cents, detail)
    values (v_referrer, v_reward, 'reward_pending', greatest(coalesce(v_est, 0), 0), jsonb_build_object('code', v_code, 'estimated', true))
    on conflict do nothing;
    perform referral_notify_client(v_referrer, 'new_referral', 'Nouveau parrainage',
      'Une nouvelle réservation a utilisé votre code HAYEVA. Votre prime est en attente de validation.', 'new_referral:' || v_reward);
    perform referral_evaluate_reward(v_reward);
  end if;
  return jsonb_build_object('ok', true, 'already', false, 'status', 'PENDING');
end;
$$;

-- ---------------------------------------------------------------------
-- 8) Codes : génération / changement / historique
-- ---------------------------------------------------------------------
create or replace function public.generate_referral_code()
returns text
language plpgsql
set search_path = public
as $$
declare alphabet constant text := 'ABCDEFGHJKMNPQRSTUVWXYZ23456789'; v text; i int;
begin
  loop
    v := '';
    for i in 1..8 loop v := v || substr(alphabet, 1 + floor(random() * length(alphabet))::int, 1); end loop;
    exit when not referral_code_taken(v, null);
  end loop;
  return v;
end;
$$;

create or replace function public.generate_referral_code_for(p_client uuid)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare v_base text; v text; i int := 0;
begin
  select left(regexp_replace(upper(translate(coalesce(first_name, ''),
           'àâäáãåçéèêëíìîïñóòôöõúùûüýÿÀÂÄÁÃÅÇÉÈÊËÍÌÎÏÑÓÒÔÖÕÚÙÛÜÝ',
           'aaaaaaceeeeiiiinooooouuuuyyAAAAAACEEEEIIIINOOOOOUUUUY')), '[^A-Z]', '', 'g'), 8)
    into v_base from clients where id = p_client;
  if coalesce(length(v_base), 0) >= 3 then
    loop
      i := i + 1;
      v := v_base || (10 + floor(random() * 90))::int::text;
      exit when not referral_code_taken(v, null);
      if i > 20 then exit; end if;
    end loop;
    if i <= 20 then return v; end if;
  end if;
  return generate_referral_code();
end;
$$;

create or replace function public.admin_suggest_referral_code(p_first_name text)
returns text
language plpgsql
stable
security definer
set search_path = public
as $$
declare v_base text; v text; i int;
begin
  if not is_admin() then raise exception 'Accès réservé à l''administration.'; end if;
  v_base := left(regexp_replace(upper(translate(coalesce(p_first_name, ''),
           'àâäáãåçéèêëíìîïñóòôöõúùûüýÿÀÂÄÁÃÅÇÉÈÊËÍÌÎÏÑÓÒÔÖÕÚÙÛÜÝ',
           'aaaaaaceeeeiiiinooooouuuuyyAAAAAACEEEEIIIINOOOOOUUUUY')), '[^A-Z]', '', 'g'), 10);
  if length(v_base) < 2 then v_base := 'HAYEVA'; end if;
  for i in 1..99 loop
    v := v_base || lpad(i::text, 2, '0');
    if length(v) >= 6 and not referral_code_taken(v, null) then return v; end if;
  end loop;
  return generate_referral_code();
end;
$$;

create or replace function public.admin_set_referrer_code(p_client_id uuid, p_code text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare v_code text := upper(regexp_replace(coalesce(p_code, ''), '\s', '', 'g')); v_old text;
begin
  if not is_admin() then raise exception 'Accès réservé à l''administration.'; end if;
  if v_code !~ '^[A-Z0-9]{6,12}$' or v_code !~ '[A-Z]' then return jsonb_build_object('ok', false, 'error', 'FORMAT'); end if;
  select code into v_old from referral_codes where client_id = p_client_id for update;
  if v_old is null then return jsonb_build_object('ok', false, 'error', 'INTROUVABLE'); end if;
  if v_old = v_code then return jsonb_build_object('ok', true, 'code', v_code, 'link', 'https://hayeva.fr/rdv?ref=' || v_code); end if;
  if referral_code_taken(v_code, p_client_id) then return jsonb_build_object('ok', false, 'error', 'CODE_EXISTANT'); end if;
  begin
    insert into referral_code_history (client_id, code, retired_by) values (p_client_id, v_old, auth.uid()) on conflict (code) do nothing;
    update referral_codes set code = v_code, created_by = coalesce(created_by, auth.uid()), updated_at = now() where client_id = p_client_id;
  exception when unique_violation then
    return jsonb_build_object('ok', false, 'error', 'CODE_EXISTANT');
  end;
  insert into referral_events (event, detail) values ('ADMIN_CODE_CHANGED', jsonb_build_object('client_id', p_client_id, 'old_code', v_old, 'code', v_code, 'by', auth.uid()));
  return jsonb_build_object('ok', true, 'code', v_code, 'old_code', v_old, 'link', 'https://hayeva.fr/rdv?ref=' || v_code);
end;
$$;

create or replace function public.set_my_referral_code(p_code text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare v_client uuid; v_code text := upper(regexp_replace(coalesce(p_code, ''), '\s', '', 'g')); v_old text;
begin
  v_client := public.ensure_my_client();
  if v_code !~ '^[A-Z0-9]{6,12}$' or v_code !~ '[A-Z]' then
    return jsonb_build_object('ok', false, 'error', 'FORMAT');
  end if;
  if exists (select 1 from referrals where referrer_client_id = v_client)
     or exists (select 1 from referral_codes where client_id = v_client and (created_by is not null or status <> 'active')) then
    return jsonb_build_object('ok', false, 'error', 'CODE_DEJA_UTILISE');
  end if;
  if referral_code_taken(v_code, v_client) then
    return jsonb_build_object('ok', false, 'error', 'CODE_INDISPONIBLE');
  end if;
  select code into v_old from referral_codes where client_id = v_client;
  begin
    if v_old is not null and v_old <> v_code then
      insert into referral_code_history (client_id, code) values (v_client, v_old) on conflict (code) do nothing;
    end if;
    insert into referral_codes (client_id, code) values (v_client, v_code)
    on conflict (client_id) do update set code = excluded.code, updated_at = now();
  exception when unique_violation then
    return jsonb_build_object('ok', false, 'error', 'CODE_INDISPONIBLE');
  end;
  return jsonb_build_object('ok', true, 'code', v_code);
end;
$$;

create or replace function public.admin_create_referrer(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_first text := nullif(trim(coalesce(p->>'first_name', '')), '');
  v_last text := nullif(trim(coalesce(p->>'last_name', '')), '');
  v_email text := lower(trim(coalesce(p->>'email', '')));
  v_phone text := nullif(trim(coalesce(p->>'phone', '')), '');
  v_code text := upper(regexp_replace(coalesce(p->>'code', ''), '\s', '', 'g'));
  v_type text := coalesce(nullif(p->>'participant_type', ''), 'individual');
  v_client uuid; v_existing text; s referral_settings%rowtype;
begin
  if not is_admin() then raise exception 'Accès réservé à l''administration.'; end if;
  select * into s from referral_settings where id;
  if not s.manual_creation_enabled then return jsonb_build_object('ok', false, 'error', 'CREATION_DESACTIVEE'); end if;
  if v_first is null then return jsonb_build_object('ok', false, 'error', 'PRENOM'); end if;
  if v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then return jsonb_build_object('ok', false, 'error', 'EMAIL'); end if;
  if v_code = '' then v_code := admin_suggest_referral_code(v_first); end if;
  if v_code !~ '^[A-Z0-9]{6,12}$' or v_code !~ '[A-Z]' then return jsonb_build_object('ok', false, 'error', 'FORMAT'); end if;
  if v_type not in ('individual', 'business') then return jsonb_build_object('ok', false, 'error', 'TYPE'); end if;
  if referral_code_taken(v_code, null) then return jsonb_build_object('ok', false, 'error', 'CODE_EXISTANT'); end if;
  v_client := find_or_create_client(null, v_email, v_phone, v_first, v_last, null);
  select code into v_existing from referral_codes where client_id = v_client;
  if v_existing is not null then
    return jsonb_build_object('ok', false, 'error', 'DEJA_PARRAIN', 'code', v_existing, 'client_id', v_client);
  end if;
  begin
    insert into referral_codes (client_id, code, participant_type, status, created_by)
    values (v_client, v_code, v_type, 'active', auth.uid());
  exception when unique_violation then
    return jsonb_build_object('ok', false, 'error', 'CODE_EXISTANT');
  end;
  insert into referral_events (event, detail) values ('ADMIN_REFERRER_CREATED', jsonb_build_object('client_id', v_client, 'code', v_code, 'type', v_type, 'by', auth.uid()));
  return jsonb_build_object('ok', true, 'client_id', v_client, 'code', v_code, 'link', 'https://hayeva.fr/rdv?ref=' || v_code);
end;
$$;

create or replace function public.admin_set_referrer_status(p_client_id uuid, p_status text)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare v_id uuid;
begin
  if not is_admin() then raise exception 'Accès réservé à l''administration.'; end if;
  if p_status not in ('active', 'suspended') then raise exception 'Statut invalide.'; end if;
  update referral_codes set status = p_status, updated_at = now() where client_id = p_client_id;
  if not found then raise exception 'Parrain introuvable.'; end if;
  insert into referral_events (event, detail) values ('ADMIN_REFERRER_STATUS', jsonb_build_object('client_id', p_client_id, 'status', p_status, 'by', auth.uid()));
  if p_status = 'suspended' then
    update referral_rewards set review_flags = array(select distinct f from unnest(review_flags || array['ADMIN_FLAG']) f), updated_at = now()
     where referrer_client_id = p_client_id and status in ('PENDING', 'REVIEW') and not ('ADMIN_FLAG' = any(review_flags));
  else
    update referral_rewards set review_flags = array_remove(review_flags, 'ADMIN_FLAG'), updated_at = now()
     where referrer_client_id = p_client_id and status in ('PENDING', 'REVIEW') and 'ADMIN_FLAG' = any(review_flags);
  end if;
  for v_id in select id from referral_rewards where referrer_client_id = p_client_id and status in ('PENDING', 'REVIEW') loop
    perform referral_evaluate_reward(v_id);
  end loop;
  return p_status;
end;
$$;

-- ---------------------------------------------------------------------
-- 9) Validation manuelle (montant calculé par les règles) et paiement manuel
-- ---------------------------------------------------------------------
create or replace function public.admin_validate_referral_reward(p_reward_id uuid, p_paid_cents integer, p_note text default null)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare w referral_rewards%rowtype; s referral_settings%rowtype; v_booking uuid; v_ins int; v_final int;
begin
  if not is_admin() then raise exception 'Accès réservé à l''administration.'; end if;
  select * into s from referral_settings where id;
  select * into w from referral_rewards where id = p_reward_id for update;
  if not found then raise exception 'Prime introuvable.'; end if;
  if w.status = 'VALIDATED' then return 'ALREADY_VALIDATED'; end if;
  if w.status not in ('PENDING', 'REVIEW') then raise exception 'Cette prime n''est plus validable (statut %).', w.status; end if;
  if coalesce(p_paid_cents, 0) < s.min_eligible_paid_cents then
    raise exception 'Montant payé inférieur au seuil de % : aucune prime.', referral_euros(s.min_eligible_paid_cents);
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
  v_final := referral_compute_reward(v_booking, p_paid_cents);
  if v_final <= 0 then raise exception 'Aucune règle de récompense active pour cette prestation : configurez-la dans Parrainages > Configuration.'; end if;
  insert into referral_ledger (referrer_client_id, reward_id, entry_type, amount_cents, detail, created_by)
  values (w.referrer_client_id, w.id, 'reward_validated', v_final,
          jsonb_build_object('booking_id', v_booking, 'paid_amount_cents', p_paid_cents, 'source', 'admin', 'note', p_note), auth.uid())
  on conflict do nothing;
  get diagnostics v_ins = row_count;
  if v_ins = 0 then return 'ALREADY_VALIDATED'; end if;
  update referral_rewards set status = 'VALIDATED', status_code = 'ADMIN_VALIDATED', status_reason = nullif(trim(coalesce(p_note, '')), ''),
         booking_id = v_booking, paid_amount_cents = p_paid_cents, validation_source = 'admin', amount_cents = v_final, amount_known = true,
         validated_at = now(), validated_by = auth.uid(), updated_at = now()
   where id = w.id;
  perform _referral_after_validation(w.id);
  return 'VALIDATED';
end;
$$;

-- Règlement manuel (aucun virement automatique) : les primes validées
-- sélectionnées d'un même parrain sont enregistrées comme PAYÉES.
create or replace function public.admin_mark_rewards_paid(p_reward_ids uuid[], p_reference text default null, p_note text default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare v_client uuid; v_n int; v_total int; v_id uuid; v_no bigint;
begin
  if not is_admin() then raise exception 'Accès réservé à l''administration.'; end if;
  if p_reward_ids is null or array_length(p_reward_ids, 1) is null then raise exception 'Aucune prime sélectionnée.'; end if;
  perform 1 from referral_rewards where id = any(p_reward_ids) for update;
  select count(distinct referrer_client_id), min(referrer_client_id::text)::uuid into v_n, v_client from referral_rewards where id = any(p_reward_ids);
  if v_n <> 1 then raise exception 'Les primes doivent appartenir à un seul parrain.'; end if;
  if exists (select 1 from referral_rewards where id = any(p_reward_ids) and (status <> 'VALIDATED' or payout_id is not null or clawback_alert)) then
    raise exception 'Seules des primes validées, non réglées et hors demande de versement peuvent être marquées payées.';
  end if;
  select coalesce(sum(amount_cents), 0) into v_total from referral_rewards where id = any(p_reward_ids);
  insert into referral_payout_requests (referrer_client_id, amount_cents, status, approved_at, paid_at, payment_reference, admin_note, processed_by)
  values (v_client, v_total, 'PAID', now(), now(), nullif(trim(coalesce(p_reference, '')), ''), coalesce(nullif(trim(coalesce(p_note, '')), ''), 'Règlement manuel'), auth.uid())
  returning id, public_no into v_id, v_no;
  update referral_rewards set payout_id = v_id, updated_at = now() where id = any(p_reward_ids);
  insert into referral_ledger (referrer_client_id, payout_id, entry_type, amount_cents, detail, created_by)
  values (v_client, v_id, 'payout_paid', v_total, jsonb_build_object('manual', true, 'reward_ids', to_jsonb(p_reward_ids), 'reference', p_reference), auth.uid());
  perform referral_notify_client(v_client, 'payout_paid', 'Prime réglée', 'Le règlement de ' || referral_euros(v_total) || ' a été enregistré.', 'payout_paid:' || v_id);
  return jsonb_build_object('ok', true, 'payout_no', v_no, 'amount_cents', v_total);
end;
$$;

-- ---------------------------------------------------------------------
-- 10) Configuration
-- ---------------------------------------------------------------------
create or replace function public.admin_save_reward_rule(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id uuid := nullif(p->>'id', '')::uuid;
  v_scope text := coalesce(nullif(p->>'scope_type', ''), 'default');
  v_value text := nullif(trim(coalesce(p->>'scope_value', '')), '');
  v_mode text := coalesce(nullif(p->>'mode', ''), 'fixed');
  v_fixed int := nullif(p->>'fixed_cents', '')::int;
  v_bp int := nullif(p->>'percent_bp', '')::int;
  v_max int := nullif(p->>'max_cents', '')::int;
  v_active boolean := coalesce((p->>'is_active')::boolean, true);
  v_label text := nullif(trim(coalesce(p->>'label', '')), '');
begin
  if not is_admin() then raise exception 'Accès réservé à l''administration.'; end if;
  if v_scope = 'default' then v_value := null; end if;
  if v_scope <> 'default' and v_value is null then return jsonb_build_object('ok', false, 'error', 'CIBLE'); end if;
  if v_mode = 'fixed' and coalesce(v_fixed, 0) <= 0 then return jsonb_build_object('ok', false, 'error', 'MONTANT'); end if;
  if v_mode = 'percent' and (coalesce(v_bp, 0) <= 0 or v_bp > 10000) then return jsonb_build_object('ok', false, 'error', 'POURCENTAGE'); end if;
  if v_max is not null and v_max <= 0 then v_max := null; end if;
  if v_id is null then
    insert into referral_reward_rules (scope_type, scope_value, label, mode, fixed_cents, percent_bp, max_cents, is_active, updated_by)
    values (v_scope, v_value, v_label, v_mode, case when v_mode = 'fixed' then v_fixed end, case when v_mode = 'percent' then v_bp end, v_max, v_active, auth.uid())
    on conflict (scope_type, coalesce(scope_value, '')) do update set label = excluded.label, mode = excluded.mode, fixed_cents = excluded.fixed_cents,
      percent_bp = excluded.percent_bp, max_cents = excluded.max_cents, is_active = excluded.is_active, updated_at = now(), updated_by = auth.uid()
    returning id into v_id;
  else
    update referral_reward_rules set scope_type = v_scope, scope_value = v_value, label = v_label, mode = v_mode,
           fixed_cents = case when v_mode = 'fixed' then v_fixed end, percent_bp = case when v_mode = 'percent' then v_bp end,
           max_cents = v_max, is_active = v_active, updated_at = now(), updated_by = auth.uid()
     where id = v_id;
  end if;
  insert into referral_events (event, detail) values ('ADMIN_RULE_SAVED', p || jsonb_build_object('by', auth.uid()));
  -- Montant indicatif public (bloc du site) = règle « toutes prestations » en montant fixe.
  update referral_settings set referrer_reward_cents = coalesce((select fixed_cents from referral_reward_rules where scope_type = 'default' and is_active and mode = 'fixed'), referrer_reward_cents)
   where id;
  return jsonb_build_object('ok', true, 'id', v_id);
exception when unique_violation then
  return jsonb_build_object('ok', false, 'error', 'DOUBLON');
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
    'business_program_public_enabled', s.business_program_public_enabled,
    'payouts_enabled', s.payouts_enabled,
    'reward_cents', (select fixed_cents from referral_reward_rules where scope_type = 'default' and is_active and mode = 'fixed'),
    'reward_rules_uniform', not exists (select 1 from referral_reward_rules where is_active and (scope_type <> 'default' or mode <> 'fixed')),
    'min_eligible_paid_cents', s.min_eligible_paid_cents,
    'min_payout_cents', s.min_payout_cents)
  from referral_settings s where s.id;
$$;

-- ---------------------------------------------------------------------
-- 11) Lectures (parrain / administration)
-- ---------------------------------------------------------------------
create or replace function public.get_my_ambassador()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare v_client uuid; v_had boolean; v_code text; s referral_settings%rowtype; rc referral_codes%rowtype;
begin
  v_client := public.ensure_my_client();
  select exists (select 1 from referral_codes where client_id = v_client) into v_had;
  v_code := public.get_my_referral_code();
  select * into rc from referral_codes where client_id = v_client;
  select * into s from referral_settings where id;
  return jsonb_build_object(
    'code', v_code,
    'code_created', not v_had,
    'code_customizable', not exists (select 1 from referrals where referrer_client_id = v_client) and rc.created_by is null,
    'participant_type', rc.participant_type,
    'participant_status', rc.status,
    'config', public.get_referral_public_config(),
    'balances', public.referral_balances(v_client),
    'has_active_payout', exists (select 1 from referral_payout_requests where referrer_client_id = v_client and status in ('REQUESTED', 'REVIEWING', 'APPROVED')),
    'referrals', coalesce((
      select jsonb_agg(jsonb_build_object(
               'ref', 'Client #' || rf.public_no,
               'status', case when p.status = 'PAID' then 'PAID' else rw.status end,
               'label', case when p.status = 'PAID' then 'Prime réglée' else public.referral_public_label(rw.status, rw.status_code, s.min_eligible_paid_cents) end,
               'amount_cents', case when rw.amount_known then rw.amount_cents end,
               'created_at', rw.created_at,
               'validated_at', rw.validated_at) order by rw.created_at desc)
        from referral_rewards rw join referrals rf on rf.id = rw.referral_id left join referral_payout_requests p on p.id = rw.payout_id
       where rw.referrer_client_id = v_client), '[]'::jsonb),
    'payouts', coalesce((
      select jsonb_agg(jsonb_build_object('no', p.public_no, 'amount_cents', p.amount_cents, 'status', p.status,
               'requested_at', p.requested_at, 'paid_at', p.paid_at) order by p.requested_at desc)
        from referral_payout_requests p where p.referrer_client_id = v_client), '[]'::jsonb),
    'notifications', coalesce((
      select jsonb_agg(jsonb_build_object('id', n.id, 'kind', n.kind, 'title', n.title, 'body', n.body, 'created_at', n.created_at, 'read', n.read_at is not null) order by n.created_at desc)
        from (select * from referral_notifications where client_id = v_client order by created_at desc limit 20) n), '[]'::jsonb),
    'wallet_balance_cents', coalesce((select balance_cents from wallet_balances where client_id = v_client), 0),
    'invited_by', (select jsonb_build_object('status', status) from referrals where referee_client_id = v_client)
  );
end;
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
        'client_id', c.id, 'name', trim(coalesce(c.first_name, '') || ' ' || coalesce(c.last_name, '')), 'email', c.email, 'phone', c.phone,
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
      where (q is null
          or lower(trim(coalesce(c.first_name, '') || ' ' || coalesce(c.last_name, ''))) like '%' || q || '%'
          or lower(rc.code) like '%' || q || '%'
          or exists (select 1 from referral_code_history h where h.client_id = c.id and lower(h.code) like '%' || q || '%')
          or lower(coalesce(c.email, '')) like '%' || q || '%'
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
    'client', (select jsonb_build_object('id', c.id, 'name', trim(coalesce(c.first_name, '') || ' ' || coalesce(c.last_name, '')), 'email', c.email, 'phone', c.phone)
                 from clients c where c.id = p_client_id),
    'code', rc.code,
    'link', case when rc.code is not null then 'https://hayeva.fr/rdv?ref=' || rc.code end,
    'old_codes', coalesce((select jsonb_agg(jsonb_build_object('code', h.code, 'retired_at', h.retired_at) order by h.retired_at desc) from referral_code_history h where h.client_id = p_client_id), '[]'::jsonb),
    'participant_type', rc.participant_type,
    'status', rc.status,
    'created_at', rc.created_at,
    'balances', referral_balances(p_client_id),
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
      select jsonb_agg(jsonb_build_object('id', a.id, 'no', a.public_no, 'legal_name', a.legal_name, 'contact_name', a.contact_name,
               'email', a.email, 'phone', a.phone, 'siren', a.siren, 'siret', a.siret, 'message', a.message, 'status', a.status,
               'created_at', a.created_at, 'admin_note', a.admin_note, 'client_id', a.client_id) order by a.created_at desc)
        from (select * from referral_business_applications order by created_at desc limit 100) a), '[]'::jsonb)
  );
end;
$$;

-- ---------------------------------------------------------------------
-- 12) Droits
-- ---------------------------------------------------------------------
revoke all on function public.referral_rule_for_booking(uuid) from public, anon, authenticated;
revoke all on function public.referral_compute_reward(uuid, integer) from public, anon, authenticated;
revoke all on function public.referral_estimate_reward(uuid) from public, anon, authenticated;
revoke all on function public.referral_code_taken(text, uuid) from public, anon, authenticated;
revoke all on function public.referral_balances(uuid) from public, anon, authenticated;
revoke all on function public.referral_evaluate_reward(uuid) from public, anon, authenticated;
revoke all on function public._attach_referral(uuid, text) from public, anon, authenticated;
revoke all on function public.generate_referral_code() from public, anon, authenticated;
revoke all on function public.generate_referral_code_for(uuid) from public, anon, authenticated;
revoke all on function public.admin_mark_rewards_paid(uuid[], text, text) from public, anon;
revoke all on function public.admin_save_reward_rule(jsonb) from public, anon;
grant execute on function public.admin_mark_rewards_paid(uuid[], text, text), public.admin_save_reward_rule(jsonb) to authenticated;
