-- ============================================================
-- "Grand jeu de lancement HAYEVA" — version 2 du cahier des charges
-- ============================================================
-- Complète 0041 (participations PENDING/VALIDATED/CANCELLED) avec :
--   1) le report du démarrage réel des interventions HAYEVA au
--      2 janvier 2027 (remplace la règle du 1er novembre 2026 de 0018,
--      pour TOUT le site — demande explicite, confirmée par l'utilisateur :
--      aucune réservation, campagne ou non, ne doit cibler une date
--      d'intervention avant cette date) ;
--   2) un 4e statut de participation, REVIEW_REQUIRED, pour les dossiers
--      qui ne doivent ni gagner ni être exclus automatiquement (annulation
--      à l'initiative de HAYEVA, ou signalement manuel admin) et doivent
--      être tranchés par un humain avant le tirage ;
--   3) le tirage au sort lui-même : préparé (fonctions + tables), mais
--      protégé par un garde-fou de date en dur (31 janvier 2027) — un appel
--      prématuré échoue explicitement, jamais de tirage accidentel.
--
-- Aucune de ces fonctions n'est appelée automatiquement : seule une action
-- explicite d'un admin (bouton dédié, voir index.html) peut les déclencher,
-- et le tirage réel reste bloqué avant la date même si on essaie.

-- ------------------------------------------------------------
-- 1) Report de l'ouverture réelle au 2 janvier 2027
-- ------------------------------------------------------------
create or replace function enforce_hayeva_opening_date()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if NEW.date < date '2027-01-02' and not (is_admin() or auth.role() = 'service_role') then
    raise exception 'HAYEVA planifie ses interventions à partir du 2 janvier 2027 — aucun rendez-vous avant cette date.';
  end if;
  return NEW;
end;
$$;
-- Le trigger trg_enforce_hayeva_opening_date (0018) pointe déjà vers cette
-- fonction par son nom : le remplacer ici suffit, pas besoin de le recréer.

-- ------------------------------------------------------------
-- 2) Statut REVIEW_REQUIRED + colonnes de traçabilité
-- ------------------------------------------------------------
alter table launch_campaign_entries drop constraint if exists launch_campaign_entries_status_check;
alter table launch_campaign_entries add constraint launch_campaign_entries_status_check
  check (status in ('PENDING','VALIDATED','CANCELLED','REVIEW_REQUIRED'));

alter table launch_campaign_entries drop constraint if exists launch_campaign_entries_invalid_reason_check;
alter table launch_campaign_entries add constraint launch_campaign_entries_invalid_reason_check
  check (invalid_reason in (
    'cancelled_by_customer', 'no_show', 'duplicate_participant',
    'hayeva_cancelled',   -- annulation à l'initiative de HAYEVA -> REVIEW_REQUIRED
    'manual_review',      -- signalement manuel par un admin -> REVIEW_REQUIRED
    'admin_review'        -- résolution manuelle d'un dossier REVIEW_REQUIRED -> CANCELLED
  ));

alter table launch_campaign_entries add column if not exists validated_at timestamptz;
alter table launch_campaign_entries add column if not exists cancelled_at timestamptz;
alter table launch_campaign_entries add column if not exists reviewed_at timestamptz;
alter table launch_campaign_entries add column if not exists admin_note text;

comment on column launch_campaign_entries.hayeva_cancelled_at is 'Horodatage d''une annulation faite par HAYEVA elle-même (cancelled_by=''admin'' sur la réservation) — trace même une fois le dossier passé en REVIEW_REQUIRED puis résolu.';

-- ------------------------------------------------------------
-- 3) Trigger de suivi de statut — version 2 (REVIEW_REQUIRED au lieu de
-- rester PENDING lors d'une annulation HAYEVA, voir règle 12 du cahier des
-- charges : le droit du client n'est jamais supprimé automatiquement, mais
-- le dossier doit maintenant être visible comme "à vérifier" plutôt que
-- simplement "en attente" comme les autres).
-- ------------------------------------------------------------
create or replace function launch_campaign_on_booking_status_change()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if NEW.status is distinct from OLD.status then
    if NEW.status = 'COMPLETED' then
      update launch_campaign_entries
        set status = 'VALIDATED', invalid_reason = null, validated_at = now(), updated_at = now()
        where booking_id = NEW.id and status = 'PENDING';

    elsif NEW.status = 'CANCELLED' then
      if NEW.cancelled_by = 'admin' then
        -- Annulation HAYEVA : ne pas pénaliser le client — dossier à
        -- vérifier manuellement (voir admin_resolve_launch_entry ci-dessous),
        -- jamais exclu automatiquement du tirage.
        update launch_campaign_entries
          set status = 'REVIEW_REQUIRED', invalid_reason = 'hayeva_cancelled',
              hayeva_cancelled_at = now(), reviewed_at = null, updated_at = now()
          where booking_id = NEW.id and status = 'PENDING';
      else
        update launch_campaign_entries
          set status = 'CANCELLED', invalid_reason = 'cancelled_by_customer', cancelled_at = now(), updated_at = now()
          where booking_id = NEW.id and status = 'PENDING';
      end if;

    elsif NEW.status = 'NO_SHOW' then
      update launch_campaign_entries
        set status = 'CANCELLED', invalid_reason = 'no_show', cancelled_at = now(), updated_at = now()
        where booking_id = NEW.id and status = 'PENDING';

    elsif NEW.status in ('CONFIRMED','IN_PROGRESS','PENDING') then
      -- Filet de sécurité (réactivation d'un rendez-vous précédemment
      -- annulé/terminé par erreur) : reste hors REVIEW_REQUIRED (laissé à
      -- la résolution manuelle explicite, voir admin_resolve_launch_entry)
      -- et hors duplicate_participant (verrouillé définitivement).
      update launch_campaign_entries
        set status = 'PENDING', invalid_reason = null, hayeva_cancelled_at = null,
            validated_at = null, cancelled_at = null, updated_at = now()
        where booking_id = NEW.id
          and status in ('CANCELLED','VALIDATED')
          and (invalid_reason is null or invalid_reason <> 'duplicate_participant');
    end if;
  end if;
  return NEW;
end;
$$;

-- ------------------------------------------------------------
-- 4) Résolution manuelle des dossiers REVIEW_REQUIRED (admin uniquement) —
-- seules écritures possibles sur launch_campaign_entries depuis le
-- frontend, toujours via ces fonctions SECURITY DEFINER qui vérifient
-- elles-mêmes is_admin(), jamais par un update direct de la table (RLS ne
-- donne aucune policy insert/update/delete, voir 0041).
-- ------------------------------------------------------------
create or replace function admin_flag_launch_entry_for_review(p_entry_id uuid, p_note text default null)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not is_admin() then
    raise exception 'Accès refusé.';
  end if;
  update launch_campaign_entries
    set status = 'REVIEW_REQUIRED', invalid_reason = 'manual_review', reviewed_at = null,
        admin_note = coalesce(p_note, admin_note), updated_at = now()
    where id = p_entry_id
      and status in ('PENDING','VALIDATED','CANCELLED')
      and (invalid_reason is null or invalid_reason <> 'duplicate_participant');
end;
$$;
revoke all on function admin_flag_launch_entry_for_review(uuid, text) from public;
grant execute on function admin_flag_launch_entry_for_review(uuid, text) to authenticated;

create or replace function admin_resolve_launch_entry(p_entry_id uuid, p_resolution text, p_note text default null)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not is_admin() then
    raise exception 'Accès refusé.';
  end if;
  if p_resolution not in ('VALIDATED','CANCELLED') then
    raise exception 'Résolution invalide : %', p_resolution;
  end if;
  update launch_campaign_entries
    set status = p_resolution,
        reviewed_at = now(),
        validated_at = case when p_resolution = 'VALIDATED' then now() else validated_at end,
        cancelled_at = case when p_resolution = 'CANCELLED' then now() else cancelled_at end,
        invalid_reason = case when p_resolution = 'CANCELLED' then 'admin_review' else null end,
        admin_note = coalesce(p_note, admin_note),
        updated_at = now()
    where id = p_entry_id and status = 'REVIEW_REQUIRED';
end;
$$;
revoke all on function admin_resolve_launch_entry(uuid, text, text) from public;
grant execute on function admin_resolve_launch_entry(uuid, text, text) to authenticated;

-- ------------------------------------------------------------
-- 5) Tirage au sort — préparé, jamais exécuté ici. Traçable : chaque
-- lot attribué est une ligne, jamais un Math.random() côté navigateur.
-- ------------------------------------------------------------
-- Une ligne = un tirage réellement exécuté (jamais un tirage "en attente" :
-- admin_launch_draw_readiness() ci-dessous répond à "peut-on le lancer ?"
-- par une simple lecture, sans avoir besoin d'une ligne ici avant coup).
create table launch_contest_draws (
  id uuid primary key default gen_random_uuid(),
  draw_date date not null default date '2027-01-31',
  executed_at timestamptz not null default now(),
  executed_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now()
);

create table launch_contest_winners (
  id uuid primary key default gen_random_uuid(),
  draw_id uuid not null references launch_contest_draws(id) on delete cascade,
  lot_key text not null check (lot_key in ('lot1','lot2','lot3')),
  entry_id uuid not null references launch_campaign_entries(id),
  booking_id uuid not null references bookings(id),
  assigned_at timestamptz not null default now(),
  unique (draw_id, lot_key),
  unique (draw_id, entry_id) -- une participation ne peut pas gagner 2 lots du même tirage
);

alter table launch_contest_draws enable row level security;
alter table launch_contest_winners enable row level security;
create policy "launch_contest_draws: admin read" on launch_contest_draws for select using (is_admin());
create policy "launch_contest_winners: admin read" on launch_contest_winners for select using (is_admin());
revoke all on table launch_contest_draws from anon, authenticated;
revoke all on table launch_contest_winners from anon, authenticated;
grant select on table launch_contest_draws to authenticated;
grant select on table launch_contest_winners to authenticated;

-- Lecture seule, appelable à tout moment sans aucun risque (ne fait aucune
-- écriture) : l'admin l'utilise pour "préparer" le tirage, càd voir
-- combien de participations seraient éligibles et si des dossiers
-- REVIEW_REQUIRED bloquent encore le lancement.
create or replace function admin_launch_draw_readiness()
returns table(eligible_count int, review_required_count int, ready boolean, draw_date date, is_draw_day boolean, already_drawn boolean)
language plpgsql
security definer
set search_path = public
stable
as $$
begin
  if not is_admin() then
    raise exception 'Accès refusé.';
  end if;
  return query
    select
      (select count(*)::int from launch_campaign_entries where status = 'VALIDATED'),
      (select count(*)::int from launch_campaign_entries where status = 'REVIEW_REQUIRED'),
      (select count(*) from launch_campaign_entries where status = 'REVIEW_REQUIRED') = 0,
      date '2027-01-31',
      now() >= (timestamp '2027-01-31 00:00:00' at time zone 'Europe/Paris'),
      exists (select 1 from launch_contest_draws);
end;
$$;
revoke all on function admin_launch_draw_readiness() from public;
grant execute on function admin_launch_draw_readiness() to authenticated;

-- Exécution réelle du tirage : verrouillée par la date (échoue avant le 31
-- janvier 2027 même appelée par erreur), par la présence de dossiers
-- REVIEW_REQUIRED non résolus, et ne peut être lancée qu'une seule fois.
-- Un gagnant est choisi aléatoirement CÔTÉ SERVEUR (random() de Postgres,
-- jamais côté navigateur) parmi les participations VALIDATED, sans jamais
-- attribuer deux lots à la même participation.
create or replace function admin_run_launch_draw()
returns table(lot_key text, entry_id uuid, booking_id uuid)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_review_count int;
  v_draw_id uuid;
  v_lot_key text;
  v_winner_id uuid;
  v_winner_booking_id uuid;
  v_picked uuid[] := '{}';
begin
  if not is_admin() then
    raise exception 'Accès refusé.';
  end if;

  if now() < (timestamp '2027-01-31 00:00:00' at time zone 'Europe/Paris') then
    raise exception 'Le tirage ne peut pas être lancé avant le 31 janvier 2027.';
  end if;

  if exists (select 1 from launch_contest_draws) then
    raise exception 'Le tirage a déjà été effectué.';
  end if;

  select count(*) into v_review_count from launch_campaign_entries where status = 'REVIEW_REQUIRED';
  if v_review_count > 0 then
    raise exception 'Impossible de lancer le tirage : % dossier(s) encore à vérifier (statut À VÉRIFIER).', v_review_count;
  end if;

  insert into launch_contest_draws (draw_date, executed_at, executed_by)
  values (date '2027-01-31', now(), auth.uid())
  returning id into v_draw_id;

  for v_lot_key in select unnest(array['lot1','lot2','lot3']) loop
    select e.id, e.booking_id into v_winner_id, v_winner_booking_id
    from launch_campaign_entries e
    where e.status = 'VALIDATED'
      and not (e.id = any(v_picked))
    order by random()
    limit 1;

    if v_winner_id is null then
      raise exception 'Pas assez de participations validées pour attribuer tous les lots.';
    end if;

    insert into launch_contest_winners (draw_id, lot_key, entry_id, booking_id)
    values (v_draw_id, v_lot_key, v_winner_id, v_winner_booking_id);

    v_picked := array_append(v_picked, v_winner_id);
    lot_key := v_lot_key;
    entry_id := v_winner_id;
    booking_id := v_winner_booking_id;
    return next;
  end loop;
  return;
end;
$$;
revoke all on function admin_run_launch_draw() from public;
grant execute on function admin_run_launch_draw() to authenticated;

-- ------------------------------------------------------------
-- 6) Lecture par le PROPRIÉTAIRE de la réservation (Espace Client/Pro —
-- badge "Jeu de lancement" dans Mes rendez-vous), en plus de l'admin
-- (policy déjà posée par 0041, inchangée).
-- ------------------------------------------------------------
create policy "launch_campaign_entries: owner read" on launch_campaign_entries
  for select using (
    exists (
      select 1 from bookings b
      where b.id = launch_campaign_entries.booking_id
        and (
          b.customer_user_id = auth.uid()
          or b.professional_account_id in (select my_professional_account_ids())
        )
    )
  );
