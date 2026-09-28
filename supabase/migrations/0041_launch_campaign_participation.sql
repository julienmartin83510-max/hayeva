-- ============================================================
-- "Grand jeu de lancement HAYEVA" — participations au tirage au sort
-- ============================================================
-- Complément de la section marketing statique déjà livrée côté frontend
-- (bloc "GRAND JEU DE LANCEMENT HAYEVA" sur la page d'accueil) : ici, on
-- décide QUI participe réellement au tirage du 23 décembre 2026.
--
-- Règle centrale demandée : une simple réservation ne suffit pas. La
-- participation créée à la réservation reste PENDING tant que
-- l'intervention n'a pas réellement été effectuée ; elle ne devient
-- VALIDATED (seul statut tiré au sort) que lorsque l'admin marque la
-- réservation COMPLETED (menu déroulant de statut déjà existant dans la
-- fiche détaillée du planning — voir admOpenBookingModal côté frontend,
-- aucune nouvelle action admin nécessaire pour ça).
--
-- Choix d'implémentation : une TABLE alimentée par des triggers
-- SECURITY DEFINER sur bookings (même style que
-- enforce_hayeva_opening_date, 0018), plutôt qu'une vue calculée à la
-- volée — pour rester cohérent avec le reste du schéma (RLS + policies
-- is_admin(), comme promo_codes 0033) et permettre un contrôle d'accès
-- simple et déjà éprouvé. Aucune écriture n'est jamais possible depuis le
-- frontend (aucune policy insert/update/delete pour anon/authenticated) :
-- seule la logique serveur ci-dessous fait évoluer une participation,
-- jamais un appel client. Le tirage lui-même N'EST PAS implémenté ici
-- (demande explicite : préparer uniquement le système) — seules les
-- entrées VALIDATED seront éligibles le jour où il sera déclenché
-- explicitement depuis l'administration.

create table launch_campaign_entries (
  id uuid primary key default gen_random_uuid(),
  booking_id uuid not null unique references bookings(id) on delete cascade,

  -- Identité du participant, utilisée uniquement pour la détection de
  -- doublons anti-abus ci-dessous — jamais affichée telle quelle, jamais
  -- utilisée pour autre chose. 'user:'/'pro:' pour un compte connecté,
  -- 'guest:'+email normalisé pour une réservation invité (guest_email est
  -- garanti non nul dans ce cas par la contrainte bookings_has_an_owner
  -- déjà existante).
  participant_key text not null,

  status text not null default 'PENDING' check (status in ('PENDING','VALIDATED','CANCELLED')),

  -- Motif renseigné uniquement quand status = 'CANCELLED' — permet à
  -- l'admin de comprendre immédiatement pourquoi une participation n'est
  -- pas éligible (demande explicite du cahier des charges).
  invalid_reason text check (invalid_reason in (
    'cancelled_by_customer',   -- le client a annulé son propre rendez-vous
    'no_show',                 -- rendez-vous non honoré
    'duplicate_participant'    -- ce participant a déjà une participation active
  )),

  -- Renseigné quand HAYEVA (et non le client) annule le rendez-vous : la
  -- participation reste PENDING (le droit potentiel du client n'est PAS
  -- supprimé automatiquement, demande explicite), ce champ sert juste à
  -- ce que l'admin la repère et la traite/reporte manuellement selon le
  -- règlement définitif.
  hayeva_cancelled_at timestamptz,

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index launch_campaign_entries_participant_key_idx on launch_campaign_entries (participant_key);
create index launch_campaign_entries_status_idx on launch_campaign_entries (status);

alter table launch_campaign_entries enable row level security;
-- Lecture admin uniquement (panneau "Jeu de lancement") — même principe
-- que promo_codes (0033). Aucune policy insert/update/delete : ces lignes
-- ne sont jamais modifiées depuis le frontend, uniquement par les
-- triggers SECURITY DEFINER ci-dessous.
create policy "launch_campaign_entries: admin read" on launch_campaign_entries
  for select using (is_admin());
revoke all on table launch_campaign_entries from anon, authenticated;
grant select on table launch_campaign_entries to authenticated;

-- ------------------------------------------------------------
-- Fenêtre d'éligibilité — période de lancement affichée côté frontend
-- (window.HAYEVA_LAUNCH_CAMPAIGN dans index.html : DU 1er novembre AU 1er
-- décembre 2026). Éligibilité fondée sur la date de CRÉATION de la
-- réservation (l'acte de réserver), jamais sur la date du rendez-vous :
-- c'est ce qui permet à un rendez-vous réservé pendant la période d'être
-- déplacé après le 1er décembre sans perdre sa participation (demande
-- explicite). Si les dates de la campagne changent, mettre à jour cette
-- fonction ET window.HAYEVA_LAUNCH_CAMPAIGN côté frontend.
-- ------------------------------------------------------------
create or replace function launch_campaign_is_eligible_created_at(ts timestamptz)
returns boolean
language sql
stable
as $$
  select ts >= (timestamp '2026-11-01 00:00:00' at time zone 'Europe/Paris')
     and ts <= (timestamp '2026-12-01 23:59:59.999999' at time zone 'Europe/Paris');
$$;

create or replace function launch_campaign_participant_key(b bookings)
returns text
language sql
stable
as $$
  select coalesce(
    case when b.customer_user_id is not null then 'user:' || b.customer_user_id::text end,
    case when b.professional_account_id is not null then 'pro:' || b.professional_account_id::text end,
    'guest:' || lower(trim(b.guest_email))
  );
$$;

-- ------------------------------------------------------------
-- Création de la participation à la réservation (PENDING), avec
-- détection de doublon anti-abus : un même participant (voir
-- launch_campaign_participant_key) ne peut avoir qu'une seule
-- participation active sur toute la campagne, même s'il annule et
-- réserve à nouveau — la nouvelle est alors créée directement CANCELLED
-- / duplicate_participant, visible en admin mais jamais tirable. Une
-- annulation faite par HAYEVA elle-même (hayeva_cancelled_at renseigné)
-- ne compte PAS comme "utilisée" : un client dont HAYEVA a annulé le
-- rendez-vous garde donc la possibilité d'une participation valide sur
-- une nouvelle réservation.
-- ------------------------------------------------------------
create or replace function launch_campaign_on_booking_insert()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  pkey text;
  already_used boolean;
begin
  if not launch_campaign_is_eligible_created_at(NEW.created_at) then
    return NEW;
  end if;

  pkey := launch_campaign_participant_key(NEW);

  select exists (
    select 1 from launch_campaign_entries e
    where e.participant_key = pkey
      and e.hayeva_cancelled_at is null
  ) into already_used;

  insert into launch_campaign_entries (booking_id, participant_key, status, invalid_reason)
  values (
    NEW.id,
    pkey,
    case when already_used then 'CANCELLED' else 'PENDING' end,
    case when already_used then 'duplicate_participant' else null end
  );
  return NEW;
end;
$$;

drop trigger if exists trg_launch_campaign_on_booking_insert on bookings;
create trigger trg_launch_campaign_on_booking_insert
  after insert on bookings
  for each row execute function launch_campaign_on_booking_insert();

-- ------------------------------------------------------------
-- Suivi du statut de la réservation → statut de la participation.
-- Un déplacement de rendez-vous (date/heure) ne passe jamais par ici : il
-- ne touche pas bookings.status, donc la participation existante (liée à
-- booking_id, jamais recréée) reste simplement PENDING telle quelle —
-- conforme à la demande "ne pas créer une deuxième participation".
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
      -- Intervention réellement effectuée : seul cas qui rend la
      -- participation tirable.
      update launch_campaign_entries
        set status = 'VALIDATED', invalid_reason = null, updated_at = now()
        where booking_id = NEW.id and status = 'PENDING';

    elsif NEW.status = 'CANCELLED' then
      if NEW.cancelled_by = 'admin' then
        -- Annulation à l'initiative de HAYEVA : ne PAS retirer le droit
        -- potentiel du client — la participation reste PENDING, simplement
        -- signalée pour traitement/report manuel en admin.
        update launch_campaign_entries
          set hayeva_cancelled_at = now(), updated_at = now()
          where booking_id = NEW.id and status = 'PENDING';
      else
        -- Annulation par le client lui-même : plus éligible.
        update launch_campaign_entries
          set status = 'CANCELLED', invalid_reason = 'cancelled_by_customer', updated_at = now()
          where booking_id = NEW.id and status = 'PENDING';
      end if;

    elsif NEW.status = 'NO_SHOW' then
      update launch_campaign_entries
        set status = 'CANCELLED', invalid_reason = 'no_show', updated_at = now()
        where booking_id = NEW.id and status = 'PENDING';

    elsif NEW.status in ('CONFIRMED','IN_PROGRESS','PENDING') then
      -- Filet de sécurité : si un admin annule puis réactive un rendez-vous
      -- par erreur (le menu déroulant existant le permet), la participation
      -- redevient PENDING plutôt que de rester bloquée CANCELLED — sauf un
      -- doublon anti-abus (duplicate_participant), qui reste définitif quel
      -- que soit le statut de CE rendez-vous.
      update launch_campaign_entries
        set status = 'PENDING', invalid_reason = null, hayeva_cancelled_at = null, updated_at = now()
        where booking_id = NEW.id
          and status in ('CANCELLED','VALIDATED')
          and (invalid_reason is null or invalid_reason <> 'duplicate_participant');
    end if;
  end if;
  return NEW;
end;
$$;

drop trigger if exists trg_launch_campaign_on_booking_status_change on bookings;
create trigger trg_launch_campaign_on_booking_status_change
  after update of status on bookings
  for each row execute function launch_campaign_on_booking_status_change();
