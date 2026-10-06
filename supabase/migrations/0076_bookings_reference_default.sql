-- RDV créés depuis HAYEVA Pro : référence générée automatiquement par la
-- base (même format SM-AAAA-XXXXXX que les RPC de réservation existantes,
-- qui continuent de fournir la leur).
alter table public.bookings alter column reference
  set default ('SM-' || to_char(now(), 'YYYY') || '-' || upper(substr(md5(gen_random_uuid()::text), 1, 6)));
