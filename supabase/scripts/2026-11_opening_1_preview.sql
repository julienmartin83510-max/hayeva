-- ============================================================
-- ÉTAPE 1 / 2 — APERÇU (LECTURE SEULE, ne modifie rien)
-- Réservations dont la date est antérieure au 01/11/2026
-- ============================================================
-- À exécuter dans Supabase > SQL Editor APRÈS la migration
-- 0015_booking_opening_date.sql. Ce script ne fait que des SELECT.
-- Il n'est volontairement PAS dans supabase/migrations/ : il ne doit jamais
-- être appliqué automatiquement.

-- 1) Combien de rendez-vous sont concernés, par statut
select status, count(*) as nombre
from bookings
where date < date '2026-11-01'
group by status
order by status;

-- 2) Total de ceux qui seront annulés par l'étape 2
--    (PENDING / CONFIRMED / IN_PROGRESS ; les CANCELLED, COMPLETED et
--    NO_SHOW ne sont pas modifiés)
select count(*) as a_annuler
from bookings
where date < date '2026-11-01'
  and status in ('PENDING', 'CONFIRMED', 'IN_PROGRESS');

-- 3) Détail (qui serait prévenu si les e-mails d'annulation étaient activés)
select
  b.reference,
  b.date,
  to_char(b.start_time, 'HH24:MI') as heure,
  b.status,
  s.name as prestation,
  coalesce(b.guest_name, nullif(trim(coalesce(cp.first_name, '') || ' ' || coalesce(cp.last_name, '')), ''), pa.legal_name, 'Client') as client,
  coalesce(b.guest_email, p.email) as email_client,
  b.created_at
from bookings b
left join services s on s.id = b.service_id
left join customer_profiles cp on cp.user_id = b.customer_user_id
left join profiles p on p.user_id = b.customer_user_id
left join professional_accounts pa on pa.id = b.professional_account_id
where b.date < date '2026-11-01'
order by b.date, b.start_time;
