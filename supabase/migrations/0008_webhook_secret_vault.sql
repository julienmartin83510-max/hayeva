-- ============================================================
-- Secret des triggers de notification : stocké une seule fois dans Vault
-- ============================================================
-- Constat (diagnostic net._http_response : 401 sur tous les appels récents,
-- pour notify-admin-booking ET notify-customer-*) : le secret partagé était
-- codé en dur dans CHAQUE fonction trigger (notify_admin_new_booking,
-- notify_customer_new_booking, notify_customer_status_change). Une rotation
-- du secret Edge Function (WEBHOOK_SECRET) exige alors de mettre à jour les
-- TROIS corps de fonction en même temps, sans filet — un désynchronisme
-- (comme celui qui vient de se produire) rend silencieusement toutes les
-- notifications inopérantes (les rendez-vous restent enregistrés
-- normalement, seules les notifications échouent).
--
-- Cette migration centralise le secret dans Supabase Vault (une seule
-- entrée, lue par les trois fonctions à chaque appel) : une future rotation
-- ne touche plus qu'un seul endroit.
--
-- ATTENTION AVANT D'EXÉCUTER : remplace REMPLACER_PAR_LE_SECRET par la
-- valeur ACTUELLE de WEBHOOK_SECRET (Edge Function secret) — la même que
-- celle déjà utilisée par supabase secrets set. Ne commite jamais la vraie
-- valeur.
-- Idempotent (create si absent, update sinon) : rejouable sans risque si une
-- future rotation doit repasser par cette même migration.
do $$
declare
  v_id uuid;
begin
  select id into v_id from vault.secrets where name = 'webhook_secret';
  if v_id is null then
    perform vault.create_secret('REMPLACER_PAR_LE_SECRET', 'webhook_secret', 'Jeton partagé triggers -> Edge Functions de notification');
  else
    perform vault.update_secret(v_id, 'REMPLACER_PAR_LE_SECRET');
  end if;
end $$;

create or replace function notify_admin_new_booking()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_secret text;
begin
  select decrypted_secret into v_secret from vault.decrypted_secrets where name = 'webhook_secret';
  perform net.http_post(
    url := 'https://hvlzdsuyhrhaflwutwml.supabase.co/functions/v1/notify-admin-booking',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'Authorization', 'Bearer ' || v_secret
    ),
    body := jsonb_build_object('type', 'INSERT', 'table', 'bookings', 'record', to_jsonb(NEW))
  );
  return NEW;
end;
$$;

create or replace function notify_customer_new_booking()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_secret text;
begin
  select decrypted_secret into v_secret from vault.decrypted_secrets where name = 'webhook_secret';
  perform net.http_post(
    url := 'https://hvlzdsuyhrhaflwutwml.supabase.co/functions/v1/notify-customer-booking',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'Authorization', 'Bearer ' || v_secret
    ),
    body := jsonb_build_object('type', 'INSERT', 'table', 'bookings', 'record', to_jsonb(NEW))
  );
  return NEW;
end;
$$;

create or replace function notify_customer_status_change()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_secret text;
begin
  if NEW.status is distinct from OLD.status and NEW.status in ('CONFIRMED','CANCELLED') then
    select decrypted_secret into v_secret from vault.decrypted_secrets where name = 'webhook_secret';
    perform net.http_post(
      url := 'https://hvlzdsuyhrhaflwutwml.supabase.co/functions/v1/notify-customer-status-change',
      headers := jsonb_build_object(
        'Content-Type', 'application/json',
        'Authorization', 'Bearer ' || v_secret
      ),
      body := jsonb_build_object('type', 'UPDATE', 'table', 'bookings', 'record', to_jsonb(NEW))
    );
  end if;
  return NEW;
end;
$$;
