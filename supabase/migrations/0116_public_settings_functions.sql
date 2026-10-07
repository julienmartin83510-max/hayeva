-- Remplace la lecture publique des vues travel_settings_public /
-- ai_settings_public (repassées en security_invoker, alerte « security
-- definer view » levée) par deux fonctions qui n'exposent que les colonnes
-- non sensibles, lisibles par les visiteurs non connectés.
create or replace function public.get_public_travel_settings()
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object('origin_label', origin_label, 'origin_lat', origin_lat, 'origin_lng', origin_lng,
                            'included_radius_km', included_radius_km, 'rate_per_km_cents', rate_per_km_cents)
    from travel_settings limit 1
$$;
create or replace function public.get_public_ai_enabled()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select coalesce((select enabled from ai_settings limit 1), false)
$$;
revoke all on function public.get_public_travel_settings() from public;
revoke all on function public.get_public_ai_enabled() from public;
grant execute on function public.get_public_travel_settings() to anon, authenticated;
grant execute on function public.get_public_ai_enabled() to anon, authenticated;
alter view public.travel_settings_public set (security_invoker = true);
alter view public.ai_settings_public set (security_invoker = true);
