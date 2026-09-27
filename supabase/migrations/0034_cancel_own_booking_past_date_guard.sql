-- ============================================================
-- cancel_own_booking() — refus explicite d'un rendez-vous déjà passé
-- ============================================================
-- Renfort défense-en-profondeur : le frontend (Espace Client) masque déjà
-- le bouton "Annuler mon rendez-vous" pour tout rendez-vous dont la date
-- est déjà passée (voir ecIsUpcomingModifiable() dans index.html), mais la
-- fonction RPC elle-même ne vérifiait jusqu'ici que le statut
-- (PENDING/CONFIRMED), jamais la date — contrairement à
-- reschedule_own_booking() qui, elle, refuse déjà explicitement une date
-- passée (0017_customer_reschedule_cancel.sql). Un appel direct à l'API
-- (hors interface, ex. requête rejouée) sur un rendez-vous PENDING/CONFIRMED
-- dont la date est révolue pouvait donc encore passer. Alignement pur sur
-- le comportement déjà en place pour le déplacement, aucun changement pour
-- un rendez-vous à venir.

create or replace function cancel_own_booking(p_booking_id uuid)
returns table(booking_id uuid, reference text)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_booking bookings%rowtype;
  v_secret text;
begin
  if v_uid is null then
    raise exception 'Authentification requise.';
  end if;

  select * into v_booking from bookings where id = p_booking_id and customer_user_id = v_uid;
  if not found then
    raise exception 'Réservation introuvable ou non autorisée.';
  end if;

  if v_booking.status not in ('PENDING', 'CONFIRMED') then
    raise exception 'Ce rendez-vous ne peut plus être annulé.';
  end if;

  -- Nouveau : même garde-fou que reschedule_own_booking() — un rendez-vous
  -- dont la date est déjà passée ne peut plus être annulé depuis cette
  -- fonction (il doit être clôturé par l'admin : COMPLETED/NO_SHOW).
  if v_booking.date < current_date then
    raise exception 'Ce rendez-vous est déjà passé et ne peut plus être annulé depuis cette interface.';
  end if;

  perform set_config('app.allow_status_change', 'on', true);
  update bookings
  set status = 'CANCELLED', cancelled_by = 'customer', cancelled_at = now(), updated_at = now()
  where id = p_booking_id;

  begin
    select decrypted_secret into v_secret from vault.decrypted_secrets where name = 'webhook_secret';
    perform net.http_post(
      url := 'https://hvlzdsuyhrhaflwutwml.supabase.co/functions/v1/notify-booking-change',
      headers := jsonb_build_object('Content-Type', 'application/json', 'Authorization', 'Bearer ' || v_secret),
      body := jsonb_build_object(
        'event', 'cancelled_by_customer',
        'booking_id', p_booking_id,
        'date', v_booking.date,
        'start_time', v_booking.start_time
      )
    );
  exception
    when others then
      null;
  end;

  return query select p_booking_id, v_booking.reference;
end;
$$;

revoke all on function cancel_own_booking(uuid) from public;
grant execute on function cancel_own_booking(uuid) to authenticated;
revoke execute on function cancel_own_booking(uuid) from anon;
