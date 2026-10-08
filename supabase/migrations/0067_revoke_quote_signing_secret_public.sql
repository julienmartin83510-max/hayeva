-- Correctif de sécurité (détecté pendant l'audit Apple Calendar) :
-- get_quote_signing_secret() devait être réservée à service_role (0009),
-- mais "revoke ... from public" ne retire pas les droits EXECUTE accordés
-- par défaut par Supabase aux rôles anon/authenticated. Résultat : tout
-- visiteur pouvait lire le secret de signature des devis de distance via
-- /rest/v1/rpc/get_quote_signing_secret. Seule l'Edge Function
-- calculate-travel-distance (service_role) l'utilise : aucun impact
-- fonctionnel.
revoke all on function public.get_quote_signing_secret() from public, anon, authenticated;
grant execute on function public.get_quote_signing_secret() to service_role;
