-- ============================================================
-- Restructuration non destructive du cycle de vie des rendez-vous :
-- distinction annulé-client / annulé-HAYEVA / refusé, motif structuré,
-- historique des changements de statut, index pour les archives par
-- date réelle de fin d'intervention. AUCUNE donnée existante supprimée
-- ni devinée : le statut `status` (PENDING/CONFIRMED/IN_PROGRESS/
-- COMPLETED/CANCELLED/NO_SHOW, voir bookings_status_check) reste
-- inchangé pour ne casser aucun code existant — cette migration ajoute
-- des colonnes complémentaires, jamais un nouveau statut `status`.
-- ============================================================

-- ------------------------------------------------------------
-- 1. Motif structuré d'annulation/refus (section 9 du cahier des
--    charges). admin_cancel_reason était référencée dans le frontend
--    comme "colonne facultative" mais n'a jamais été réellement créée
--    (vérifié en base) : on la remplace directement par ce schéma
--    structuré, plus utile, sans jamais avoir existé en production.
-- ------------------------------------------------------------
alter table bookings
  add column if not exists cancellation_type text
    check (cancellation_type in ('cancelled_client', 'cancelled_admin', 'refused')),
  add column if not exists cancellation_reason_code text
    check (cancellation_reason_code in (
      'creneau_indisponible', 'hors_zone', 'prestation_non_proposee',
      'client_injoignable', 'doublon', 'erreur_reservation', 'autre'
    )),
  add column if not exists cancellation_reason_detail text;

comment on column bookings.cancellation_type is 'cancelled_client : annulé par le client depuis son espace. cancelled_admin : rendez-vous CONFIRMED annulé par HAYEVA. refused : demande PENDING refusée avant confirmation. NULL = non renseigné (anciennes données, voir section 25).';

-- Rétro-remplissage PRUDENT des lignes CANCELLED existantes, à partir du
-- seul signal fiable déjà en base (cancelled_by) : jamais de distinction
-- devinée entre "refused" et "cancelled_admin" pour l'historique, faute
-- de moyen fiable de la déterminer rétroactivement (section 25 : ne pas
-- deviner). Les lignes sans cancelled_by renseigné restent NULL —
-- visibles dans l'admin comme "à vérifier" plutôt que classées à tort.
update bookings set cancellation_type = 'cancelled_client'
  where status = 'CANCELLED' and cancelled_by = 'customer' and cancellation_type is null;
update bookings set cancellation_type = 'cancelled_admin'
  where status = 'CANCELLED' and cancelled_by = 'admin' and cancellation_type is null;

-- ------------------------------------------------------------
-- 2. Historique des changements de statut (section 20) — alimenté
--    automatiquement par un trigger, jamais par une saisie manuelle
--    supplémentaire : aucun code existant n'a besoin d'être modifié
--    pour que l'historique commence à se remplir.
-- ------------------------------------------------------------
create table if not exists booking_status_history (
  id uuid primary key default gen_random_uuid(),
  booking_id uuid not null references bookings(id) on delete cascade,
  old_status text,
  new_status text not null,
  changed_at timestamptz not null default now(),
  changed_by uuid references auth.users(id),
  reason text
);

alter table booking_status_history enable row level security;
create policy "booking_status_history: customer sees own" on booking_status_history
  for select using (
    booking_id in (select id from bookings where customer_user_id = auth.uid())
  );
create policy "booking_status_history: admin full access" on booking_status_history
  for all using (is_admin()) with check (is_admin());

create index if not exists idx_booking_status_history_booking on booking_status_history(booking_id, changed_at);

create or replace function log_booking_status_change()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if (tg_op = 'INSERT') then
    insert into booking_status_history (booking_id, old_status, new_status, changed_by)
    values (new.id, null, new.status, auth.uid());
  elsif (tg_op = 'UPDATE' and old.status is distinct from new.status) then
    insert into booking_status_history (booking_id, old_status, new_status, changed_by, reason)
    values (new.id, old.status, new.status, auth.uid(), coalesce(new.cancellation_reason_detail, new.cancellation_reason_code));
  end if;
  return new;
end;
$$;

drop trigger if exists trg_booking_status_history on bookings;
create trigger trg_booking_status_history
  after insert or update of status on bookings
  for each row execute function log_booking_status_change();

-- Entrée initiale pour les rendez-vous déjà existants, pour ne pas avoir
-- un historique vide alors qu'ils ont un statut actuel connu.
insert into booking_status_history (booking_id, old_status, new_status, changed_at)
select b.id, null, b.status, b.created_at
from bookings b
where not exists (select 1 from booking_status_history h where h.booking_id = b.id);

-- ------------------------------------------------------------
-- 3. Index de performance (section 24) — les onglets Aujourd'hui/À venir
--    filtrent par (date, status), les Archives groupent par mois de fin
--    réelle d'intervention.
-- ------------------------------------------------------------
create index if not exists idx_bookings_date_status on bookings(date, status);
create index if not exists idx_interventions_ended_at on interventions(ended_at) where report_status = 'FINALIZED';
