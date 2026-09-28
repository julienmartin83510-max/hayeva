-- ============================================================
-- Demandes "parler à un humain" envoyées depuis l'Assistant IA
-- ============================================================
-- Portée additive : aucune table/fonction existante modifiée. Réutilise le
-- même patron de sécurité que ai_conversations/ai_messages
-- (0023_ai_assistant.sql) : écriture UNIQUEMENT via l'Edge Function dédiée
-- (service_role), jamais directement par anon/authenticated — empêche un
-- visiteur de forger de fausses demandes ou de spammer l'admin en insérant
-- directement des lignes.
--
-- Déclenchement : l'Edge Function ai-request-human (appelée par le widget
-- assistant, public ET Espace Client/Pro connecté) UNIQUEMENT quand l'IA ne
-- peut/doit pas traiter seule la demande — réponse de sécurité (gaz/feu) ou
-- assistant indisponible/saturé — jamais à chaque message, pour ne jamais
-- noyer l'admin d'alertes. Elle envoie l'alerte admin (e-mail + push,
-- réutilisant sendAdminAlert/sendAdminPush du même patron que
-- notify-booking-change) directement dans son propre corps, sans passer par
-- un trigger AFTER INSERT + pg_net : un seul appel client = une seule
-- écriture = une seule notification, aucun risque de doublon par listener
-- multiple.
create table ai_human_requests (
  id uuid primary key default gen_random_uuid(),
  conversation_id uuid references ai_conversations(id) on delete set null,
  session_id uuid,
  customer_type text check (customer_type in ('particulier','professionnel')),
  reason text,
  last_message text,
  contact_name text,
  contact_phone text,
  contact_email text,
  created_at timestamptz not null default now(),
  admin_viewed_at timestamptz
);
create index ai_human_requests_created_idx on ai_human_requests (created_at desc);

alter table ai_human_requests enable row level security;
create policy "ai_human_requests: admin read" on ai_human_requests
  for select using (is_admin());
create policy "ai_human_requests: admin update viewed" on ai_human_requests
  for update using (is_admin()) with check (is_admin());
revoke all on table ai_human_requests from anon, authenticated;
grant select, update on table ai_human_requests to authenticated;
