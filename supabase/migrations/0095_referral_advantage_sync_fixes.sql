-- PARRAINAGE — compléments :
-- * l'état de l'avantage filleul est initialisé dès la création du
--   parrainage, même si la 1re réservation n'y donne pas droit (prestation
--   sous le montant minimum) ;
-- * toute nouvelle réservation d'un filleul relance l'évaluation (récompense
--   parrain + avantage filleul), par ex. après l'annulation de la première.
create or replace function public.referral_reconcile_booking_advantage(p_booking uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare b bookings%rowtype; r referrals%rowtype;
begin
  select * into b from bookings where id = p_booking;
  if not found then return; end if;
  select * into r from referrals where referee_client_id = b.client_id;
  if found and r.referee_advantage_status is null then
    perform referral_sync_referee_advantage(r.id);
    select * into r from referrals where id = r.id;
  end if;
  if b.referral_advantage_cents <= 0 then return; end if;
  if r.id is null or r.status = 'INELIGIBLE' or coalesce(r.referee_advantage_status, '') in ('CANCELLED', 'USED', 'NONE')
     or (r.referee_advantage_status = 'APPLIED' and r.referee_advantage_booking_id is distinct from b.id) then
    perform _referral_set_booking_discount(b.id, b.discount_cents - b.referral_advantage_cents, 0);
    return;
  end if;
  perform referral_sync_referee_advantage(r.id);
end;
$$;

create or replace function public.referral_booking_after_insert()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if exists (select 1 from referrals where referee_client_id = NEW.client_id) then
    begin
      perform referral_evaluate_for_client(NEW.client_id);
    exception when others then
      insert into referral_events (event, detail) values ('PROCESS_ERROR', jsonb_build_object('booking_id', NEW.id, 'error', SQLERRM, 'op', 'advantage_insert'));
    end;
  end if;
  return null;
end;
$$;

revoke all on function public.referral_reconcile_booking_advantage(uuid) from public, anon, authenticated;
revoke all on function public.referral_booking_after_insert() from public, anon, authenticated;
