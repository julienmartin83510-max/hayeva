-- Défense en profondeur (audit de mise en production) : generate_reminder_jobs()
-- n'est appelée que par la tâche pg_cron hayeva-reminder-cycle (exécutée en
-- tant que propriétaire de la base). Elle est idempotente, mais aucun
-- visiteur ni client n'a de raison de pouvoir la déclencher via /rest/v1/rpc.
revoke all on function public.generate_reminder_jobs() from public, anon, authenticated;
