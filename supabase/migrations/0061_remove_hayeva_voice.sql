-- ============================================================
-- Suppression complète de HAYEVA Voice (téléphonie IA) — décision du
-- propriétaire du site : pas de service de téléphonie IA payant.
-- ============================================================
-- Portée : uniquement les objets créés par 0035_voice_assistant_core.sql,
-- 0037_voice_telephony_prep.sql, 0038_voice_realtime_browser.sql et
-- 0048_voice_transcription_fallback.sql (0036 n'ajoutait que des colonnes
-- sur des tables déjà supprimées ici, rien de séparé à retirer).
--
-- Vérifié avant écriture de cette migration : aucune autre migration ne
-- référence ces tables (pas de clé étrangère pointant vers elles depuis une
-- table non-voice), aucune fonction/Edge Function restante ne les
-- interroge, et get_available_slots_for_service() n'est appelée nulle part
-- ailleurs dans le projet (outil dédié au moteur conversationnel vocal,
-- jamais la logique de disponibilité réelle du tunnel de réservation
-- — qui reste sudAvailability côté frontend + ses propres RPC, inchangés).
--
-- Rien de ceci ne touche : bookings, customer_addresses, clients,
-- interventions, quotes, invoices, service_contracts, reminder_jobs,
-- ai_conversations/ai_messages/ai_settings/ai_usage_daily (assistant texte
-- "Assistant Hayeva", conservé), ai_human_requests (transfert humain du
-- chat texte, conservé) — aucune de ces tables n'est touchée.

drop table if exists voice_transcription_usage_daily cascade;
drop table if exists voice_realtime_usage_daily cascade;
drop table if exists voice_callback_requests cascade;
drop table if exists voice_telephony_settings cascade;
drop table if exists voice_test_bookings cascade;
drop table if exists voice_call_events cascade;
drop table if exists voice_call_sessions cascade;
drop table if exists voice_assistant_settings cascade;

drop function if exists get_available_slots_for_service(text, date, integer);
