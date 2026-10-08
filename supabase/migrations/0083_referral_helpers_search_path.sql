-- Conseiller sécurité Supabase (function_search_path_mutable) : search_path
-- figé sur les trois fonctions utilitaires du programme de parrainage.
alter function public.referral_euros(integer) set search_path = public;
alter function public.referral_public_label(text, text, integer) set search_path = public;
alter function public.referral_ledger_immutable() set search_path = public;
