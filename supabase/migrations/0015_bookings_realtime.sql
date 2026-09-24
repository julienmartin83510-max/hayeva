-- ============================================================
-- Active Supabase Realtime sur bookings (Administration → Demandes
-- récentes / Planning / Devis / Tableau de bord)
-- ============================================================
-- Aucun changement de structure (colonnes/tables) ni de policy RLS : les
-- policies existantes sur bookings ("bookings: owner or admin read",
-- 0001_init.sql) s'appliquent déjà telles quelles aux événements Realtime
-- (postgres_changes) — un admin reçoit tous les événements INSERT/UPDATE,
-- exactement ce qu'il peut déjà lire via une requête normale, jamais plus.
-- Il manquait uniquement l'enregistrement de la table dans la publication
-- "supabase_realtime" (infrastructure de réplication, pas un changement de
-- schéma applicatif), sans quoi aucun événement n'est jamais diffusé, quelle
-- que soit la policy RLS.
--
-- Idempotent : ALTER PUBLICATION ... ADD TABLE échoue si la table est déjà
-- membre de la publication ("already member of publication"), donc on
-- vérifie d'abord via pg_publication_tables avant de l'ajouter — rejouable
-- sans risque si cette migration est appliquée plusieurs fois.
do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'bookings'
  ) then
    alter publication supabase_realtime add table bookings;
  end if;
end $$;
