-- ============================================================
-- HAYEVA Voice — Phase 1 (suite) : informations collectées + anti-double-
-- réservation atomique sur les données de TEST.
-- ============================================================
-- Portée additive uniquement, aucune table/colonne existante retirée ou
-- modifiée dans son comportement pour la production.

-- ------------------------------------------------------------
-- Informations progressivement comprises par l'assistant pendant l'appel
-- (record_customer_info, voir tools.ts) — affichées telles quelles dans le
-- simulateur ("Non renseigné" tant qu'un champ est null, jamais inventé).
alter table voice_call_sessions
  add column if not exists customer_name text,
  add column if not exists customer_phone text,
  add column if not exists customer_address text,
  add column if not exists customer_city text,
  add column if not exists problem_description text,
  add column if not exists urgency_level text check (urgency_level in ('normale', 'elevee', 'urgence')),
  add column if not exists desired_date date,
  add column if not exists desired_slot_label text;

-- ------------------------------------------------------------
-- Anti-double-réservation ATOMIQUE, y compris entre données de TEST —
-- même principe que bookings_no_overlapping_slots (0001_init.sql), mais
-- appliquée à voice_test_bookings pour que le TEST 4 (tentative de double
-- réservation) du cahier des charges soit une garantie réelle du serveur/
-- de la base, pas seulement un ordre d'exécution favorable côté code.
-- N'affecte jamais la table de production `bookings`, ni sa propre
-- contrainte, qui reste strictement inchangée.
alter table voice_test_bookings
  add constraint voice_test_bookings_no_overlap
  exclude using gist (
    tsrange(
      (date + start_time),
      (date + start_time + (duration_minutes * interval '1 minute'))
    ) with &&
  )
  where (status = 'CONFIRMED');
