-- 0118 — Règle absolue : aucun rendez-vous sans compte HAYEVA authentifié.
-- Appliquée AU NIVEAU DE LA TABLE (trigger BEFORE INSERT) : couvre tous les
-- chemins client — create_booking, create_guest_or_quote_booking, insert
-- direct PostgREST — quel que soit le frontend utilisé.
-- Exemptés : administrateurs (is_admin) et appels serveur sans JWT client
-- (service_role, triggers internes, cron).

create or replace function public.bookings_require_account()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_claims jsonb;
  v_role text;
  v_uid uuid := auth.uid();
  v_phone text;
  v_recent integer;
begin
  begin
    v_claims := nullif(current_setting('request.jwt.claims', true), '')::jsonb;
  exception when others then v_claims := null;
  end;
  v_role := coalesce(v_claims ->> 'role', '');
  if v_role not in ('anon', 'authenticated') then
    return NEW; -- appel serveur (service_role / interne)
  end if;
  if v_uid is not null and public.is_admin() then
    return NEW;
  end if;

  if v_uid is null then
    raise exception 'Connexion requise : connectez-vous à votre espace HAYEVA pour prendre rendez-vous.'
      using errcode = '42501';
  end if;
  if not exists (select 1 from auth.users u where u.id = v_uid and u.email_confirmed_at is not null) then
    raise exception 'Merci de confirmer votre adresse e-mail (lien reçu par e-mail) avant de prendre rendez-vous.'
      using errcode = '42501';
  end if;

  -- Rattachement obligatoire au compte authentifié.
  if NEW.customer_user_id is not null then
    if NEW.customer_user_id <> v_uid then
      raise exception 'Réservation non rattachée à votre compte.' using errcode = '42501';
    end if;
  elsif NEW.professional_account_id is null
     or NEW.professional_account_id not in (select public.my_professional_account_ids()) then
    raise exception 'Connexion requise : connectez-vous à votre espace HAYEVA pour prendre rendez-vous.'
      using errcode = '42501';
  end if;

  -- Téléphone exploitable (compte particulier).
  if NEW.customer_user_id is not null then
    select phone into v_phone from public.customer_profiles where user_id = v_uid;
    if length(regexp_replace(coalesce(v_phone, ''), '\D', '', 'g')) not between 9 and 15 then
      raise exception 'Merci de renseigner un numéro de téléphone valide pour prendre rendez-vous.';
    end if;
  end if;

  -- Sérialise les demandes d'un même compte (double clic simultané).
  perform pg_advisory_xact_lock(hashtext('hayeva_booking_account_' || v_uid::text));

  if exists (
    select 1 from public.bookings b
     where b.date = NEW.date and b.start_time = NEW.start_time
       and b.status in ('PENDING', 'CONFIRMED', 'IN_PROGRESS')
       and (b.customer_user_id = v_uid
            or (NEW.professional_account_id is not null and b.professional_account_id = NEW.professional_account_id))
  ) then
    raise exception 'Vous avez déjà une demande de rendez-vous sur ce créneau.';
  end if;

  select count(*) into v_recent from public.bookings b
   where b.created_at > now() - interval '24 hours'
     and (b.customer_user_id = v_uid
          or (NEW.professional_account_id is not null and b.professional_account_id = NEW.professional_account_id));
  if v_recent >= 5 then
    raise exception 'Trop de demandes de rendez-vous en 24 h. Contactez HAYEVA directement si besoin.';
  end if;

  return NEW;
end;
$$;

create or replace trigger trg_bookings_a_require_account
  before insert on public.bookings
  for each row execute function public.bookings_require_account();

-- RLS : plus aucune insertion "invité" (customer_user_id NULL) possible.
alter policy "bookings: create own or guest" on public.bookings
  with check (
    is_admin()
    or ((customer_user_id is not null) and (customer_user_id = (select auth.uid())))
    or ((professional_account_id is not null) and (professional_account_id in (select my_professional_account_ids())))
  );
alter policy "bookings: create own or guest" on public.bookings rename to "bookings: create own (account required)";

-- Plus aucun appel anonyme des fonctions de réservation / d'action e-mail
-- (l'Edge Function booking-email-action utilise la clé serveur).
revoke execute on function public.create_guest_or_quote_booking(text, date, time without time zone, text, text, text, text, text, text, text, text, boolean, boolean, text) from public, anon;
revoke execute on function public.process_booking_email_action(text, text, boolean) from public, anon, authenticated;
