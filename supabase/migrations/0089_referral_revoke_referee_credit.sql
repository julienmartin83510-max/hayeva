-- PARRAINAGE — révocation complète
-- 1) Une récompense révoquée (RDV annulé/supprimé, facture annulée/supprimée,
--    remboursement) retire aussi l'avantage de bienvenue crédité au filleul
--    dans sa cagnotte (écriture ADJUSTMENT négative, jamais de solde négatif ;
--    si l'avantage a déjà été utilisé, alerte « vérification requise »).
-- 2) Le journal de cagnotte reste immuable, sauf la seule mise à NULL du lien
--    vers un rendez-vous supprimé (clé étrangère ON DELETE SET NULL).

create or replace function public.wallet_tx_immutable()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if tg_op = 'UPDATE' and OLD.booking_id is not null and NEW.booking_id is null
     and (to_jsonb(NEW) - 'booking_id') = (to_jsonb(OLD) - 'booking_id') then
    return NEW;
  end if;
  raise exception 'Le journal de cagnotte est immuable.';
end $$;

create or replace function public._referral_revoke_referee_credit(p_referral_id uuid, p_reason text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare v_credit wallet_transactions%rowtype; v_bal int; v_take int;
begin
  select * into v_credit from wallet_transactions where referral_id = p_referral_id and type = 'REFERRAL_REFEREE';
  if not found then return; end if;
  if exists (select 1 from wallet_transactions where referral_id = p_referral_id and type = 'ADJUSTMENT' and reason like 'Annulation de l''avantage parrainage%') then
    return;
  end if;
  select balance_cents into v_bal from wallet_balances where client_id = v_credit.client_id for update;
  v_take := least(v_credit.amount_cents, greatest(coalesce(v_bal, 0), 0));
  if v_take > 0 then
    insert into wallet_transactions (client_id, type, amount_cents, reason, referral_id)
    values (v_credit.client_id, 'ADJUSTMENT', -v_take, 'Annulation de l''avantage parrainage — ' || p_reason, p_referral_id);
  end if;
  if v_take < v_credit.amount_cents then
    perform admin_notify('payment', 'Parrainage — vérification requise',
      'Avantage de bienvenue du filleul déjà utilisé (' || referral_euros(v_credit.amount_cents - v_take) || ') — ' || p_reason || ' — vérification requise',
      null, 'referral-referee-credit:' || p_referral_id, true);
  end if;
end;
$$;

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
      perform _referral_revoke_referee_credit(w.referral_id, p_reason);
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
  perform _referral_revoke_referee_credit(w.referral_id, p_reason);
  perform admin_notify('payment', 'Récompense de parrainage annulée', p_reason || ' : récompense annulée.', w.booking_id, 'referral-revoke:' || w.id, false);
  return 'REVOKED';
end;
$$;

-- Annulation manuelle d'une récompense validée : même retrait de l'avantage filleul.
create or replace function public.admin_reject_referral_reward(p_reward_id uuid, p_reason text)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare w referral_rewards%rowtype; v_reason text := coalesce(nullif(trim(p_reason), ''), 'Refusé par l''administration');
begin
  if not is_admin() then raise exception 'Accès réservé à l''administration.'; end if;
  select * into w from referral_rewards where id = p_reward_id for update;
  if not found then raise exception 'Prime introuvable.'; end if;
  if w.status = 'VALIDATED' then
    if w.payout_id is not null and _referral_detach_from_payout(w.id, v_reason) = 'PAID' then
      raise exception 'Prime déjà versée : régularisation à traiter manuellement.';
    end if;
    update referral_rewards set status = 'CANCELLED', status_code = 'ADMIN_CANCELLED', status_reason = v_reason,
           cancelled_at = now(), updated_at = now() where id = w.id;
    insert into referral_ledger (referrer_client_id, reward_id, entry_type, amount_cents, detail, created_by)
    values (w.referrer_client_id, w.id, 'reward_cancelled', -w.amount_cents, jsonb_build_object('reason', v_reason, 'by', 'admin'), auth.uid())
    on conflict do nothing;
    perform _referral_revoke_referee_credit(w.referral_id, v_reason);
  else
    update referral_rewards set status = 'REJECTED', status_code = 'ADMIN_REJECTED', status_reason = v_reason, updated_at = now() where id = w.id;
  end if;
  update referrals set status = 'INELIGIBLE', status_reason = v_reason, updated_at = now() where id = w.referral_id;
  insert into referral_events (referral_id, event, detail) values (w.referral_id, 'ADMIN_REJECTED', jsonb_build_object('reason', v_reason, 'by', auth.uid()));
  return 'REJECTED';
end;
$$;

revoke all on function public._referral_revoke_referee_credit(uuid, text) from public, anon, authenticated;
revoke all on function public._referral_revoke_validated(uuid, text, text) from public, anon, authenticated;
