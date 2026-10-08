-- 0120 — Parcours réservation / authentification : derniers points.
--
-- 1) Brouillon de réservation CÔTÉ SERVEUR (prestation, date, heure,
--    options, commentaire, identifiant de créneau), rattaché au compte :
--    - à l'inscription, le brouillon voyage dans les métadonnées Supabase
--      Auth du compte (stockées par Supabase, pas dans le navigateur) ;
--    - « Mot de passe oublié » : brouillon déposé pour l'e-mail (24 h),
--      récupérable uniquement par le compte vérifié de cet e-mail ;
--    - à la première connexion, sur N'IMPORTE QUEL navigateur/appareil
--      (Safari, Chrome, navigateur intégré de Gmail…), get_my_booking_draft()
--      rattache le brouillon au compte (table booking_drafts, 72 h).
-- 2) Identité de la réservation imposée par le serveur : pour toute
--    réservation créée par un compte (hors admin), nom / téléphone saisis
--    sont ignorés (le compte fait foi) et l'e-mail est celui du compte
--    Supabase Auth vérifié.

create table if not exists public.booking_drafts (
  user_id uuid primary key references auth.users(id) on delete cascade,
  payload jsonb not null,
  meta_claimed_ts bigint,
  updated_at timestamptz not null default now(),
  expires_at timestamptz not null
);
alter table public.booking_drafts enable row level security;
revoke all on public.booking_drafts from anon, authenticated;

create table if not exists public.booking_draft_stash (
  email_norm text primary key,
  payload jsonb not null,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null
);
alter table public.booking_draft_stash enable row level security;
revoke all on public.booking_draft_stash from anon, authenticated;

-- Validation stricte : liste blanche de champs, types et tailles.
create or replace function public._booking_draft_clean(p jsonb)
returns jsonb
language plpgsql
stable
set search_path = public
as $$
declare
  v_service text := p ->> 'serviceId';
  v_date text := p ->> 'date';
  v_time integer;
  v_it text := p ->> 'installType';
  v_uc text := p ->> 'unitCount';
  v_comment text := left(coalesce(p ->> 'comment', ''), 1000);
begin
  if p is null or jsonb_typeof(p) <> 'object' then return null; end if;
  if v_service is null or v_service !~ '^[a-z0-9-]{2,80}$' then return null; end if;
  if v_date is not null and v_date !~ '^\d{4}-\d{2}-\d{2}$' then return null; end if;
  begin
    v_time := nullif(p ->> 'time', '')::integer;
  exception when others then return null;
  end;
  if v_time is not null and (v_time < 0 or v_time > 1439) then return null; end if;
  if v_it is not null and v_it not in ('mono', 'multi') then v_it := null; end if;
  if v_uc is not null and v_uc not in ('2', '3', '4') then v_uc := null; end if;
  return jsonb_build_object(
    'v', 1,
    'serviceId', v_service,
    'date', v_date,
    'time', v_time,
    'slotId', case when v_date is not null and v_time is not null
                   then v_date || 'T' || lpad((v_time / 60)::text, 2, '0') || ':' || lpad((v_time % 60)::text, 2, '0') end,
    'installType', v_it,
    'unitCount', v_uc,
    'comment', v_comment,
    'ts', coalesce(nullif(p ->> 'ts', '')::bigint, (extract(epoch from now()) * 1000)::bigint)
  );
exception when others then
  return null;
end;
$$;

create or replace function public.save_my_booking_draft(p_payload jsonb)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v jsonb := public._booking_draft_clean(p_payload);
begin
  if v_uid is null or v is null then return false; end if;
  insert into public.booking_drafts (user_id, payload, updated_at, expires_at)
  values (v_uid, v, now(), now() + interval '72 hours')
  on conflict (user_id) do update set payload = excluded.payload, updated_at = now(), expires_at = excluded.expires_at;
  return true;
end;
$$;

-- Lecture (et rattachement) du brouillon du compte connecté et vérifié.
create or replace function public.get_my_booking_draft()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_email text;
  v_confirmed boolean;
  v_meta jsonb;
  v_meta_clean jsonb;
  v_row public.booking_drafts;
  v_stash public.booking_draft_stash;
begin
  if v_uid is null then return null; end if;
  select lower(u.email), u.email_confirmed_at is not null, u.raw_user_meta_data -> 'hv_booking_draft'
    into v_email, v_confirmed, v_meta
    from auth.users u where u.id = v_uid;
  if not coalesce(v_confirmed, false) then return null; end if;

  select * into v_row from public.booking_drafts where user_id = v_uid;

  -- Brouillon transmis à l'inscription (métadonnées Auth), une seule fois.
  v_meta_clean := public._booking_draft_clean(v_meta);
  if v_meta_clean is not null
     and (v_row.user_id is null or v_row.meta_claimed_ts is distinct from (v_meta_clean ->> 'ts')::bigint)
     and (v_meta_clean ->> 'ts')::bigint > (extract(epoch from now() - interval '7 days') * 1000)::bigint then
    insert into public.booking_drafts (user_id, payload, meta_claimed_ts, updated_at, expires_at)
    values (v_uid, v_meta_clean, (v_meta_clean ->> 'ts')::bigint, now(), now() + interval '72 hours')
    on conflict (user_id) do update set payload = excluded.payload, meta_claimed_ts = excluded.meta_claimed_ts,
      updated_at = now(), expires_at = excluded.expires_at;
  end if;

  -- Brouillon déposé avant « Mot de passe oublié » pour cet e-mail.
  select * into v_stash from public.booking_draft_stash where email_norm = v_email and expires_at > now();
  if found then
    insert into public.booking_drafts (user_id, payload, updated_at, expires_at)
    values (v_uid, v_stash.payload, now(), now() + interval '72 hours')
    on conflict (user_id) do update set payload = excluded.payload, updated_at = now(), expires_at = excluded.expires_at;
    update public.booking_draft_stash set expires_at = now() - interval '1 second' where email_norm = v_email;
  end if;

  select * into v_row from public.booking_drafts where user_id = v_uid;
  if v_row.user_id is null then return null; end if;
  if v_row.expires_at < now() then
    return null; -- ligne conservée : mémorise le brouillon d'inscription déjà consommé
  end if;
  return v_row.payload;
end;
$$;

create or replace function public.clear_my_booking_draft()
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null then return; end if;
  update public.booking_drafts set expires_at = now() - interval '1 second', updated_at = now() where user_id = v_uid;
  update public.booking_draft_stash set expires_at = now() - interval '1 second'
   where email_norm = (select lower(email) from auth.users where id = v_uid);
end;
$$;

-- Dépôt anonyme (uniquement depuis « Mot de passe oublié ») : rien n'est
-- lisible sans se connecter au compte vérifié de cet e-mail ; volume borné.
create or replace function public.stash_booking_draft(p_email text, p_payload jsonb)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_email text := lower(trim(coalesce(p_email, '')));
  v jsonb := public._booking_draft_clean(p_payload);
begin
  if v is null or length(v_email) > 254 or v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then return; end if;
  if (select count(*) from public.booking_draft_stash where created_at > now() - interval '1 hour') >= 300 then return; end if;
  insert into public.booking_draft_stash (email_norm, payload, created_at, expires_at)
  values (v_email, v, now(), now() + interval '24 hours')
  on conflict (email_norm) do update set payload = excluded.payload, created_at = now(), expires_at = excluded.expires_at;
end;
$$;

revoke execute on function public._booking_draft_clean(jsonb) from public, anon, authenticated;
revoke execute on function public.save_my_booking_draft(jsonb) from public, anon;
revoke execute on function public.get_my_booking_draft() from public, anon;
revoke execute on function public.clear_my_booking_draft() from public, anon;
grant execute on function public.save_my_booking_draft(jsonb) to authenticated;
grant execute on function public.get_my_booking_draft() to authenticated;
grant execute on function public.clear_my_booking_draft() to authenticated;
grant execute on function public.stash_booking_draft(text, jsonb) to anon, authenticated;

-- Identité imposée par le compte (complète 0118).
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
  v_email text;
begin
  begin
    v_claims := nullif(current_setting('request.jwt.claims', true), '')::jsonb;
  exception when others then v_claims := null;
  end;
  v_role := coalesce(v_claims ->> 'role', '');
  if v_role not in ('anon', 'authenticated') then
    return NEW;
  end if;
  if v_uid is not null and public.is_admin() then
    return NEW;
  end if;

  if v_uid is null then
    raise exception 'Connexion requise : connectez-vous à votre espace HAYEVA pour prendre rendez-vous.'
      using errcode = '42501';
  end if;
  select email into v_email from auth.users u where u.id = v_uid and u.email_confirmed_at is not null;
  if v_email is null then
    raise exception 'Merci de confirmer votre adresse e-mail (lien reçu par e-mail) avant de prendre rendez-vous.'
      using errcode = '42501';
  end if;

  if NEW.customer_user_id is not null then
    if NEW.customer_user_id <> v_uid then
      raise exception 'Réservation non rattachée à votre compte.' using errcode = '42501';
    end if;
  elsif NEW.professional_account_id is null
     or NEW.professional_account_id not in (select public.my_professional_account_ids()) then
    raise exception 'Connexion requise : connectez-vous à votre espace HAYEVA pour prendre rendez-vous.'
      using errcode = '42501';
  end if;

  -- Le compte fait foi : aucune identité saisie librement n'est conservée.
  NEW.guest_name := null;
  NEW.guest_phone := null;
  NEW.guest_email := case when NEW.guest_email is not null then v_email else null end;

  if NEW.customer_user_id is not null then
    select phone into v_phone from public.customer_profiles where user_id = v_uid;
    if length(regexp_replace(coalesce(v_phone, ''), '\D', '', 'g')) not between 9 and 15 then
      raise exception 'Merci de renseigner un numéro de téléphone valide pour prendre rendez-vous.';
    end if;
  end if;

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
