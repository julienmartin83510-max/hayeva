-- ADMIN — suivi des inscriptions clients (tableau de bord).
-- Source : date de création réelle des comptes (auth.users.created_at), donc
-- tout l'historique est compté. Type : profiles.global_role (customer =
-- particulier, professional = professionnel) ; à défaut de profil finalisé,
-- le rôle demandé à l'inscription (métadonnées). Les comptes administrateurs
-- et anonymes sont exclus. Jours / semaines / mois calculés en heure de Paris
-- (semaine commençant le lundi). Agrégats calculés côté serveur : aucune
-- liste de comptes n'est envoyée au navigateur (hors 10 dernières inscriptions).
create or replace function public.admin_signup_stats(p_range text default '7d')
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_now timestamp := now() at time zone 'Europe/Paris';
  v_today date := (now() at time zone 'Europe/Paris')::date;
  v_unit text; v_steps int; v_start timestamp;
begin
  if not is_admin() then raise exception 'Accès réservé à l''administration.'; end if;
  case coalesce(p_range, '7d')
    when '30d' then v_unit := 'day'; v_steps := 30;
    when '3m' then v_unit := 'week'; v_steps := 13;
    when '12m' then v_unit := 'month'; v_steps := 12;
    else v_unit := 'day'; v_steps := 7;
  end case;
  v_start := date_trunc(v_unit, v_now) - ((v_steps - 1) || ' ' || v_unit)::interval;
  return (
    with acc as (
      select u.id, (u.created_at at time zone 'Europe/Paris') as created_local, u.created_at,
             case coalesce(p.global_role, u.raw_user_meta_data->>'global_role', u.raw_user_meta_data->>'sud_pending_role', u.raw_user_meta_data->>'role')
               when 'customer' then 'particulier' when 'professional' then 'pro' else 'autre' end as kind
        from auth.users u left join profiles p on p.user_id = u.id
       where not coalesce(u.is_anonymous, false)
         and coalesce(p.global_role, '') <> 'admin'
    ),
    buckets as (
      select g as bucket from generate_series(v_start, date_trunc(v_unit, v_now), ('1 ' || v_unit)::interval) g
    )
    select jsonb_build_object(
      'generated_at', now(),
      'today', (select jsonb_build_object('total', count(*), 'particuliers', count(*) filter (where kind = 'particulier'), 'pros', count(*) filter (where kind = 'pro'), 'autres', count(*) filter (where kind = 'autre'))
                  from acc where created_local::date = v_today),
      'week', (select jsonb_build_object('total', count(*), 'particuliers', count(*) filter (where kind = 'particulier'), 'pros', count(*) filter (where kind = 'pro'), 'autres', count(*) filter (where kind = 'autre'))
                 from acc where created_local >= date_trunc('week', v_now)),
      'month', (select jsonb_build_object('total', count(*), 'particuliers', count(*) filter (where kind = 'particulier'), 'pros', count(*) filter (where kind = 'pro'), 'autres', count(*) filter (where kind = 'autre'))
                  from acc where created_local >= date_trunc('month', v_now)),
      'total', (select jsonb_build_object('total', count(*), 'particuliers', count(*) filter (where kind = 'particulier'), 'pros', count(*) filter (where kind = 'pro'), 'autres', count(*) filter (where kind = 'autre'))
                  from acc),
      'range', coalesce(p_range, '7d'), 'unit', v_unit,
      'series', (select jsonb_agg(jsonb_build_object('start', to_char(b.bucket, 'YYYY-MM-DD'),
                    'total', (select count(*) from acc where date_trunc(v_unit, created_local) = b.bucket),
                    'particuliers', (select count(*) from acc where date_trunc(v_unit, created_local) = b.bucket and kind = 'particulier'),
                    'pros', (select count(*) from acc where date_trunc(v_unit, created_local) = b.bucket and kind = 'pro')) order by b.bucket)
                   from buckets b),
      'recent', (select coalesce(jsonb_agg(r order by r.created_at desc), '[]'::jsonb) from (
          select a.created_at, a.kind,
                 coalesce(
                   nullif(trim((select coalesce(c.first_name, '') || ' ' || coalesce(c.last_name, '') from clients c where c.user_id = a.id and c.merged_into is null order by c.created_at limit 1)), ''),
                   (select coalesce(nullif(pa.trade_name, ''), pa.legal_name) from professional_members pm join professional_accounts pa on pa.id = pm.professional_account_id where pm.user_id = a.id limit 1)
                 ) as name
            from acc a order by a.created_at desc limit 10) r)
    )
  );
end;
$$;

revoke all on function public.admin_signup_stats(text) from public, anon;
grant execute on function public.admin_signup_stats(text) to authenticated;

-- Temps réel : nouvelle fiche profil (création de compte finalisée) → le
-- tableau de bord admin se met à jour. Les règles RLS existantes de
-- profiles s'appliquent (un client ne reçoit que son propre profil).
do $$ begin
  if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'profiles') then
    alter publication supabase_realtime add table public.profiles;
  end if;
end $$;
