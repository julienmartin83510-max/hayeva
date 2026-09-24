-- ============================================================
-- ÉTAPE 2 / 2 — ANNULATION des réservations antérieures au 01/11/2026
-- ============================================================
-- NE PAS EXÉCUTER avant d'avoir lancé l'étape 1 (aperçu) et validé le
-- nombre de rendez-vous concernés.
--
-- Ce que fait ce script :
--   * passe au statut CANCELLED les réservations PENDING / CONFIRMED /
--     IN_PROGRESS dont la date est antérieure au 01/11/2026 ;
--   * AUCUNE suppression : les lignes restent en base, visibles dans
--     l'Historique (annulés / refusés) du panneau Administration et dans
--     l'Espace Client ; aucune donnée client n'est touchée (nom, e-mail,
--     téléphone, adresse, notes, prix restent identiques) ;
--   * trace chaque annulation dans audit_logs
--     (action = 'booking.cancel_before_opening') ;
--   * les CANCELLED / COMPLETED / NO_SHOW existants ne sont pas modifiés.
--
-- E-MAILS CLIENTS : par défaut, AUCUN e-mail d'annulation n'est envoyé.
-- Le trigger trg_notify_customer_status_change (qui envoie normalement
-- "Votre demande de rendez-vous HAYEVA a été annulée" à chaque passage en
-- CANCELLED) est désactivé UNIQUEMENT pendant cette transaction, puis
-- réactivé. Pour envoyer quand même l'e-mail standard d'annulation à chaque
-- client concerné, supprimer les deux lignes "alter table ... trigger"
-- ci-dessous avant d'exécuter.
--
-- Tout se fait dans une seule transaction : en cas d'erreur, rien n'est
-- modifié.

begin;

alter table bookings disable trigger trg_notify_customer_status_change;

with annulees as (
  update bookings
  set status = 'CANCELLED'
  where date < date '2026-11-01'
    and status in ('PENDING', 'CONFIRMED', 'IN_PROGRESS')
  returning id, reference, date, start_time
), journal as (
  insert into audit_logs (actor_user_id, action, entity, entity_id)
  select null, 'booking.cancel_before_opening', 'bookings', id from annulees
)
select reference, date, start_time, 'CANCELLED' as nouveau_statut
from annulees
order by date, start_time;

alter table bookings enable trigger trg_notify_customer_status_change;

commit;

-- Vérification : doit renvoyer 0
select count(*) as reste_a_annuler
from bookings
where date < date '2026-11-01'
  and status in ('PENDING', 'CONFIRMED', 'IN_PROGRESS');
