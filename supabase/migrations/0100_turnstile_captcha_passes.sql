-- Protection anti-robot (Cloudflare Turnstile) des formulaires publics sans
-- compte : réservation invitée, candidature parrain particulier,
-- candidature apporteur d'affaires.
--
-- Principe : l'Edge Function verify-turnstile vérifie le jeton Turnstile
-- auprès de Cloudflare (secret TURNSTILE_SECRET_KEY, jamais côté
-- navigateur) puis délivre un « laissez-passer » à usage unique, valable
-- 10 minutes, propre à un formulaire. Le navigateur le transmet dans
-- l'en-tête HTTP x-hayeva-captcha de l'appel RPC ; la fonction SQL le
-- consomme avant tout traitement. Les visiteurs connectés (déjà vérifiés
-- par la CAPTCHA de connexion Supabase Auth) ne sont pas concernés.
--
-- Activation : turnstile_enforced passe à true automatiquement à la
-- première vérification Cloudflare réussie (chaîne complète opérationnelle :
-- clé de site servie au navigateur + secret serveur). Avant cela, aucun
-- formulaire n'est bloqué.

create table if not exists public.security_settings (
  id integer primary key default 1 check (id = 1),
  turnstile_enforced boolean not null default false,
  turnstile_activated_at timestamptz,
  updated_at timestamptz not null default now()
);
insert into public.security_settings (id) values (1) on conflict (id) do nothing;
alter table public.security_settings enable row level security;
revoke all on public.security_settings from anon, authenticated;

create table if not exists public.captcha_passes (
  id uuid primary key default gen_random_uuid(),
  purpose text not null check (purpose in ('booking', 'referrer_application', 'business_application')),
  ip_hash text,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null default now() + interval '10 minutes',
  used_at timestamptz
);
create index if not exists captcha_passes_ip_created_idx on public.captcha_passes (ip_hash, created_at);
create index if not exists captcha_passes_created_idx on public.captcha_passes (created_at);
alter table public.captcha_passes enable row level security;
revoke all on public.captcha_passes from anon, authenticated;

-- Consomme le laissez-passer de la requête en cours (en-tête
-- x-hayeva-captcha). Renvoie true si la requête est autorisée.
create or replace function public.captcha_check_pass(p_purpose text)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v_raw text;
  v_pass uuid;
  v_ok uuid;
begin
  if auth.uid() is not null then return true; end if;
  if not coalesce((select turnstile_enforced from security_settings where id = 1), false) then return true; end if;
  begin
    v_raw := nullif(trim(current_setting('request.headers', true)::json ->> 'x-hayeva-captcha'), '');
  exception when others then v_raw := null;
  end;
  if v_raw is null or v_raw !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then return false; end if;
  v_pass := v_raw::uuid;
  update captcha_passes set used_at = now()
   where id = v_pass and purpose = p_purpose and used_at is null and expires_at > now()
  returning id into v_ok;
  return v_ok is not null;
end;
$$;
revoke all on function public.captcha_check_pass(text) from public, anon, authenticated;
grant execute on function public.captcha_check_pass(text) to service_role;

-- Garde ajoutée en tête des trois fonctions publiques (corps existant
-- inchangé par ailleurs).
do $mig$
declare
  r record;
  v_def text;
  v_new text;
  v_guard text;
begin
  for r in
    select p.oid, p.proname from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname in ('create_guest_or_quote_booking', 'submit_referrer_application', 'submit_business_referrer_application')
  loop
    v_def := pg_get_functiondef(r.oid);
    if position('captcha_check_pass' in v_def) > 0 then continue; end if;
    v_guard := case r.proname
      when 'create_guest_or_quote_booking' then
        E'\nbegin\n  if not public.captcha_check_pass(''booking'') then\n    raise exception ''La vérification de sécurité a expiré ou n''''a pas abouti. Merci de réessayer.'';\n  end if;\n'
      when 'submit_referrer_application' then
        E'\nbegin\n  if not public.captcha_check_pass(''referrer_application'') then return jsonb_build_object(''ok'', false, ''error'', ''VERIFICATION''); end if;\n'
      else
        E'\nbegin\n  if not public.captcha_check_pass(''business_application'') then return jsonb_build_object(''ok'', false, ''error'', ''VERIFICATION''); end if;\n'
    end;
    v_new := regexp_replace(v_def, E'\\nbegin\\n', v_guard);
    if v_new = v_def or position('captcha_check_pass' in v_new) = 0 then
      raise exception 'Garde CAPTCHA non insérée dans %', r.proname;
    end if;
    execute v_new;
  end loop;
end
$mig$;
