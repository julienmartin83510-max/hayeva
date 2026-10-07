-- PARRAINAGE — workflow paiement → facture → récompense (audit final)
--
-- 1) Une récompense n'est validée QUE sur paiement confirmé :
--    * automatiquement : facture liée au RDV au statut PAYÉE (net des
--      remboursements) >= seuil ;
--    * manuellement (tant que la facturation définitive est indisponible,
--      informations entreprise incomplètes) : l'administrateur confirme
--      explicitement le paiement (montant, moyen, date, référence),
--      enregistré et tracé. Si une facture existe pour ce RDV, c'est elle
--      qui fait foi : validation manuelle refusée tant qu'elle n'est pas payée.
-- 2) Révocation d'une récompense validée si, après coup, le RDV est annulé
--    / supprimé, la facture annulée ou remboursée : annulée si non réglée,
--    alerte « vérification requise » si déjà réglée (jamais de solde négatif).
-- 3) Suppression d'un RDV (demande refusée, admin) : plus jamais bloquée par
--    le parrainage (clé étrangère ON DELETE SET NULL + réévaluation).

-- Clés étrangères : la suppression d'un rendez-vous ne doit pas être bloquée.
alter table public.referral_rewards drop constraint if exists referral_rewards_booking_id_fkey;
alter table public.referral_rewards add constraint referral_rewards_booking_id_fkey
  foreign key (booking_id) references public.bookings(id) on delete set null;
alter table public.referrals drop constraint if exists referrals_qualifying_booking_id_fkey;
alter table public.referrals add constraint referrals_qualifying_booking_id_fkey
  foreign key (qualifying_booking_id) references public.bookings(id) on delete set null;
alter table public.wallet_transactions drop constraint if exists wallet_transactions_booking_id_fkey;
alter table public.wallet_transactions add constraint wallet_transactions_booking_id_fkey
  foreign key (booking_id) references public.bookings(id) on delete set null;

-- « Validée ⇒ booking_id renseigné » : la révocation se fait dans le
-- déclencheur BEFORE DELETE ci-dessous, avant la mise à NULL. Seule exception :
-- une récompense déjà réglée (alerte « vérification requise ») reste validée
-- pour l'historique comptable, même si son RDV est supprimé.
alter table public.referral_rewards drop constraint if exists referral_rewards_check1;
alter table public.referral_rewards add constraint referral_rewards_check1
  check (status <> 'VALIDATED' or (validated_at is not null and paid_amount_cents is not null and (booking_id is not null or clawback_alert)));

-- Confirmation de paiement (validation manuelle)
alter table public.referral_rewards
  add column if not exists payment_method text,
  add column if not exists payment_date date,
  add column if not exists payment_reference text,
  add column if not exists payment_confirmed_by uuid,
  add column if not exists payment_confirmed_at timestamptz;
alter table public.referral_rewards add constraint referral_rewards_payment_method_check
  check (payment_method is null or payment_method in ('virement', 'carte', 'especes', 'cheque', 'autre'));

-- Révocation d'une récompense validée (factorisée).
create or replace function public._referral_revoke_validated(p_reward_id uuid, p_code text, p_reason text)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare w referral_rewards%rowtype;
begin
  select * into w from referral_rewards where id = p_reward_id for update;
  if not found or w.status <> 'VALIDATED' then return 'NOOP'; end if;
  if w.payout_id is not null and _referral_detach_from_payout(w.id, p_reason) = 'PAID' then
    if not w.clawback_alert then
      update referral_rewards set clawback_alert = true,
             status_reason = 'Récompense déjà réglée — ' || p_reason || ' — vérification requise', updated_at = now()
       where id = w.id;
      insert into referral_ledger (referrer_client_id, reward_id, payout_id, entry_type, amount_cents, detail)
      values (w.referrer_client_id, w.id, w.payout_id, 'reward_clawback_alert', 0, jsonb_build_object('reason', p_code))
      on conflict do nothing;
      perform admin_notify('payment', 'Parrainage — vérification requise',
        'Récompense déjà réglée — ' || p_reason || ' — vérification requise', w.booking_id, 'referral-clawback:' || w.id, true);
    end if;
    return 'CLAWBACK_ALERT';
  end if;
  update referral_rewards set status = 'CANCELLED', status_code = p_code, status_reason = p_reason || ' — récompense annulée',
         cancelled_at = now(), updated_at = now()
   where id = w.id;
  insert into referral_ledger (referrer_client_id, reward_id, entry_type, amount_cents, detail)
  values (w.referrer_client_id, w.id, 'reward_cancelled', -w.amount_cents, jsonb_build_object('reason', p_code))
  on conflict do nothing;
  update referrals set status = 'INELIGIBLE', status_reason = p_reason, updated_at = now() where id = w.referral_id;
  insert into referral_events (referral_id, event, detail) values (w.referral_id, 'REWARD_REVOKED', jsonb_build_object('reward_id', w.id, 'code', p_code));
  perform admin_notify('payment', 'Récompense de parrainage annulée', p_reason || ' : récompense annulée.', w.booking_id, 'referral-revoke:' || w.id, false);
  return 'REVOKED';
end;
$$;

-- RDV supprimé : révocation AVANT la suppression (la récompense pointe encore
-- vers le RDV), puis réévaluation des primes non validées du filleul.
create or replace function public.referral_on_booking_delete()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare v_id uuid;
begin
  begin
    for v_id in select id from referral_rewards where booking_id = OLD.id and status = 'VALIDATED' loop
      perform _referral_revoke_validated(v_id, 'REVOKED_BOOKING_DELETED', 'Rendez-vous supprimé');
    end loop;
  exception when others then
    insert into referral_events (event, detail) values ('PROCESS_ERROR', jsonb_build_object('booking_id', OLD.id, 'error', SQLERRM, 'op', 'delete'));
  end;
  return OLD;
end;
$$;
create or replace trigger trg_referral_on_booking_delete
  before delete on public.bookings
  for each row execute function public.referral_on_booking_delete();

create or replace function public.referral_after_booking_delete()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  begin
    perform referral_evaluate_for_client(OLD.client_id);
  exception when others then
    insert into referral_events (event, detail) values ('PROCESS_ERROR', jsonb_build_object('booking_id', OLD.id, 'error', SQLERRM, 'op', 'after_delete'));
  end;
  return null;
end;
$$;
create or replace trigger trg_referral_after_booking_delete
  after delete on public.bookings
  for each row execute function public.referral_after_booking_delete();

-- Facture supprimée : réévaluation du filleul concerné.
create or replace function public.referral_on_invoice_delete()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare v_client uuid;
begin
  select b.client_id into v_client from quotes q join bookings b on b.id = q.booking_id where q.id = OLD.quote_id;
  if v_client is not null then
    begin
      perform referral_evaluate_for_client(v_client);
    exception when others then
      insert into referral_events (event, detail) values ('PROCESS_ERROR', jsonb_build_object('invoice_id', OLD.id, 'error', SQLERRM, 'op', 'delete'));
    end;
  end if;
  return null;
end;
$$;
create or replace trigger trg_referral_on_invoice_delete
  after delete on public.invoices
  for each row execute function public.referral_on_invoice_delete();

-- Évaluation : branche « validée » renforcée (révocation après coup) et
-- codes de révocation définitifs. Le reste est identique à 0086.
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
  v_ins int; v_old_status text; v_old_code text; v_final int; v_est int; v_bstatus text;
begin
  select * into w from referral_rewards where id = p_reward_id for update;
  if not found then return 'NOT_FOUND'; end if;
  select * into s from referral_settings where id;
  select * into r from referrals where id = w.referral_id;
  v_old_status := w.status; v_old_code := w.status_code;

  if w.status = 'VALIDATED' then
    select status into v_bstatus from bookings where id = w.booking_id;
    select * into v_pay from referral_booking_payment(w.booking_id);
    if v_bstatus is null then
      return _referral_revoke_validated(w.id, 'REVOKED_BOOKING_DELETED', 'Rendez-vous supprimé');
    elsif v_bstatus <> 'COMPLETED' then
      return _referral_revoke_validated(w.id, 'REVOKED_BOOKING_' || v_bstatus, 'Intervention plus au statut terminé (' || v_bstatus || ')');
    elsif v_pay.has_paid and v_pay.paid_net_cents < s.min_eligible_paid_cents then
      return _referral_revoke_validated(w.id, 'REFUNDED', 'Intervention remboursée');
    elsif w.validation_source = 'auto_invoice' and not v_pay.has_paid then
      return _referral_revoke_validated(w.id, 'REVOKED_INVOICE', 'Facture payée annulée ou supprimée');
    end if;
    return 'VALIDATED';
  end if;

  if w.status_code like 'ADMIN_%' or w.status_code = 'REFUNDED' or w.status_code like 'REVOKED%' then
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
      v_reason := 'Intervention terminée — paiement non confirmé : confirmation du paiement par l''administrateur requise';
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
      perform admin_notify('payment', 'Parrainage à valider', 'Intervention terminée d''un filleul : confirmez le paiement pour valider la récompense.',
        v_booking, 'referral-awaiting:' || w.id || ':' || v_booking || ':' || v_code, false);
    end if;
  end if;
  return v_status || '/' || v_code;
end;
$$;

-- Validation manuelle sécurisée : confirmation explicite du paiement.
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
                             'payment_date', p_payment_date, 'payment_reference', p_reference, 'note', p_note), auth.uid())
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
  perform _referral_after_validation(w.id);
  return 'VALIDATED';
end;
$$;

-- L'ancienne validation sans confirmation de paiement est désactivée.
create or replace function public.admin_validate_referral_reward(p_reward_id uuid, p_paid_cents integer, p_note text default null)
returns text
language plpgsql
security definer
set search_path = public
as $$
begin
  if not is_admin() then raise exception 'Accès réservé à l''administration.'; end if;
  raise exception 'Validation sans confirmation de paiement désactivée : utilisez « Confirmer le paiement et valider ».';
end;
$$;

revoke all on function public._referral_revoke_validated(uuid, text, text) from public, anon, authenticated;
revoke all on function public.referral_on_booking_delete() from public, anon, authenticated;
revoke all on function public.referral_after_booking_delete() from public, anon, authenticated;
revoke all on function public.referral_on_invoice_delete() from public, anon, authenticated;
revoke all on function public.referral_evaluate_reward(uuid) from public, anon, authenticated;
revoke all on function public.admin_confirm_payment_and_validate(uuid, integer, text, date, text, text) from public, anon;
grant execute on function public.admin_confirm_payment_and_validate(uuid, integer, text, date, text, text) to authenticated;
