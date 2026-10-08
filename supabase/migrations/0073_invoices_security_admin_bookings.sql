-- 1) SÉCURITÉ factures : la politique existante autorisait un client à
--    créer/modifier/supprimer SES factures (with_check sur customer_user_id)
--    — ex. passer une facture en "payée". Désormais : lecture pour le
--    client propriétaire, écriture réservée à l'administration. (La
--    politique existante est conservée ; des politiques RESTRICTIVES
--    s'ajoutent en ET, plus une politique permissive admin qui manquait
--    pour l'insertion.)
create policy "invoices: admin full access" on public.invoices
  for all using (is_admin()) with check (is_admin());
create policy "invoices: write admin only (insert)" on public.invoices as restrictive for insert with check (is_admin());
create policy "invoices: write admin only (update)" on public.invoices as restrictive for update using (is_admin()) with check (is_admin());
create policy "invoices: write admin only (delete)" on public.invoices as restrictive for delete using (is_admin());

-- 2) RDV créé directement CONFIRMÉ par l'administration (HAYEVA Pro,
--    "+ Nouveau RDV") : jusqu'ici Apple Calendar et l'e-mail client
--    "Rendez-vous confirmé" ne réagissaient qu'au PASSAGE à CONFIRMED
--    (UPDATE). Un INSERT déjà CONFIRMED déclenche maintenant les mêmes
--    appels (même fonction calendar-sync, même UID hayeva-<id> : aucun
--    doublon possible). Le flux client (INSERT PENDING) est inchangé.
create or replace function public.sync_booking_to_calendar_on_insert()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_secret text;
begin
  if NEW.status <> 'CONFIRMED' then
    return NEW;
  end if;
  begin
    select decrypted_secret into v_secret from vault.decrypted_secrets where name = 'webhook_secret';
    perform net.http_post(
      url := 'https://hvlzdsuyhrhaflwutwml.supabase.co/functions/v1/calendar-sync',
      headers := jsonb_build_object('Content-Type', 'application/json', 'Authorization', 'Bearer ' || v_secret),
      body := jsonb_build_object('action', 'upsert', 'booking_id', NEW.id)
    );
    perform net.http_post(
      url := 'https://hvlzdsuyhrhaflwutwml.supabase.co/functions/v1/notify-customer-status-change',
      headers := jsonb_build_object('Content-Type', 'application/json', 'Authorization', 'Bearer ' || v_secret),
      body := jsonb_build_object('type', 'UPDATE', 'table', 'bookings', 'record', to_jsonb(NEW))
    );
  exception
    when others then null;
  end;
  return NEW;
end;
$$;
revoke all on function public.sync_booking_to_calendar_on_insert() from public, anon, authenticated;
create trigger trg_sync_booking_to_calendar_insert
  after insert on public.bookings
  for each row execute function public.sync_booking_to_calendar_on_insert();

-- E-mail admin "Nouvelle demande" : uniquement pour une DEMANDE (PENDING),
-- jamais pour un RDV que l'administrateur vient lui-même de créer confirmé.
create or replace function public.notify_admin_new_booking()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_secret text;
begin
  if NEW.status <> 'PENDING' then
    return NEW;
  end if;
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
$function$;
