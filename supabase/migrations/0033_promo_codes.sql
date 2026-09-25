-- ============================================================
-- Codes promotionnels — source de vérité pour l'Assistant Hayeva (point 6
-- du cahier des charges "Assistant commercial et technique").
-- ============================================================
-- IMPORTANT : cette table ne déclenche AUCUNE remise automatique sur une
-- réservation — elle sert uniquement à ce que l'Edge Function ai-assistant
-- puisse confirmer ou infirmer l'existence/l'activation réelle d'un code
-- annoncé par un visiteur dans le chat, sans jamais faire confiance au texte
-- tapé côté client. L'application effective d'un avantage lors d'une
-- réservation reste un sujet séparé, non traité ici (ne duplique pas le
-- système de réservation existant).
--
-- Accès : jamais en lecture/écriture directe pour anon/authenticated (même
-- principe que ai_settings) — uniquement lu par l'Edge Function via
-- service_role, et administrable par un admin (is_admin(), voir 0001_init.sql)
-- depuis le SQL Editor ou une future interface d'administration.

create table promo_codes (
  id uuid primary key default gen_random_uuid(),
  code text not null unique,          -- toujours comparé en majuscules (voir ilike côté Edge Function)
  description text not null,          -- texte exact que l'assistant est autorisé à relayer, jamais un montant inventé
  active boolean not null default false,
  starts_at timestamptz,
  ends_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  updated_by uuid references auth.users(id) on delete set null
);
create index promo_codes_code_idx on promo_codes (upper(code));

alter table promo_codes enable row level security;
create policy "promo_codes: admin read" on promo_codes
  for select using (is_admin());
create policy "promo_codes: admin write" on promo_codes
  for all using (is_admin()) with check (is_admin());
revoke all on table promo_codes from anon, authenticated;
grant select on table promo_codes to authenticated;

-- Code de test demandé explicitement (cahier des charges, point 6) — inséré
-- DÉSACTIVÉ par défaut : un admin doit l'activer volontairement (active =
-- true, éventuellement starts_at/ends_at) avant qu'il ne produise le moindre
-- effet dans les réponses de l'assistant. Tant qu'il reste inactif,
-- l'assistant répond correctement qu'il n'est "pas utilisable actuellement"
-- si un visiteur le mentionne — c'est le comportement attendu par défaut.
insert into promo_codes (code, description, active) values
  ('HAYEVA100', 'Code de test interne — description à définir par un administrateur avant activation commerciale.', false);
