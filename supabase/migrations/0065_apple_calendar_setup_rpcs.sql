-- RPC admin complémentaires pour la configuration initiale Apple Calendar
-- (section "Agenda & synchronisation") : l'administrateur saisit
-- uniquement l'identifiant Apple (email) — jamais le mot de passe
-- d'application, qui reste exclusivement dans Supabase Vault
-- (secret apple_caldav_app_password, jamais accessible au frontend) — puis
-- déclenche la découverte CalDAV (action=setup de l'Edge Function
-- calendar-sync), qui crée/retrouve le calendrier dédié "HAYEVA — Rendez-
-- vous" et liste les calendriers Apple disponibles comme sources de
-- blocage possibles.

create or replace function admin_set_apple_account(p_email text)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not is_admin() then
    raise exception 'Accès réservé à l''administration.';
  end if;
  if p_email is null or p_email = '' or p_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then
    raise exception 'Adresse Apple ID invalide.';
  end if;

  if exists (select 1 from calendar_connections) then
    update calendar_connections set apple_id_email = p_email, connected = false, updated_at = now();
  else
    insert into calendar_connections (apple_id_email, connected) values (p_email, false);
  end if;
end;
$$;

-- Déclenche la découverte CalDAV (une fois le mot de passe d'application
-- déposé dans Vault par l'administrateur via le Dashboard Supabase — seule
-- étape humaine requise, voir commentaire get_apple_caldav_app_password).
create or replace function admin_trigger_calendar_setup()
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_secret text;
begin
  if not is_admin() then
    raise exception 'Accès réservé à l''administration.';
  end if;
  if not exists (select 1 from calendar_connections where apple_id_email is not null) then
    raise exception 'Renseignez d''abord l''identifiant Apple (email).';
  end if;
  select decrypted_secret into v_secret from vault.decrypted_secrets where name = 'webhook_secret';
  perform net.http_post(
    url := 'https://hvlzdsuyhrhaflwutwml.supabase.co/functions/v1/calendar-sync',
    headers := jsonb_build_object('Content-Type', 'application/json', 'Authorization', 'Bearer ' || v_secret),
    body := jsonb_build_object('action', 'setup')
  );
end;
$$;

revoke all on function admin_set_apple_account(text) from public, anon, authenticated;
revoke all on function admin_trigger_calendar_setup() from public, anon, authenticated;
grant execute on function admin_set_apple_account(text) to authenticated;
grant execute on function admin_trigger_calendar_setup() to authenticated;
