-- HAYEVA Pro — finalisation : stock à la validation, notifications admin,
-- informations entreprise, déplacement par l'admin sans e-mail admin.

-- ========== 1) STOCK : déduction à la VALIDATION de l'intervention ==========
-- Une pièce du stock ajoutée à une fiche ne touche pas l'inventaire tant que
-- l'intervention n'est pas validée (report_status = FINALIZED). À la
-- validation, chaque pièce reliée au stock est déduite UNE seule fois
-- (stock_deducted_qty mémorise la quantité réellement déduite : aucune
-- double déduction possible, même si la validation est rejouée). Une pièce
-- hors stock (stock_item_id null) n'a aucun effet sur l'inventaire.
alter table public.intervention_parts add column if not exists stock_deducted_qty numeric(12,2);

-- L'ancien trigger (0072, déduction dès l'ajout) est conservé mais sa
-- fonction ne fait plus que re-créditer une pièce déjà déduite supprimée.
create or replace function public.stock_on_intervention_part()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if tg_op = 'DELETE' and OLD.stock_deducted_qty is not null and OLD.stock_item_id is not null then
    insert into stock_movements (stock_item_id, delta, reason, intervention_id, intervention_part_id, note)
    values (OLD.stock_item_id, OLD.stock_deducted_qty, 'annulation_intervention', OLD.intervention_id, OLD.id, 'Pièce retirée après validation');
  end if;
  return coalesce(NEW, OLD);
end;
$$;

create or replace function public.stock_deduct_for_intervention(p_intervention_id uuid)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  r record;
  n integer := 0;
begin
  for r in
    select * from intervention_parts
     where intervention_id = p_intervention_id and stock_item_id is not null and stock_deducted_qty is null
     for update
  loop
    insert into stock_movements (stock_item_id, delta, reason, intervention_id, intervention_part_id)
    values (r.stock_item_id, -coalesce(r.quantity, 0), 'intervention', p_intervention_id, r.id);
    update intervention_parts set stock_deducted_qty = coalesce(r.quantity, 0) where id = r.id;
    n := n + 1;
  end loop;
  return n;
end;
$$;
revoke all on function public.stock_deduct_for_intervention(uuid) from public, anon, authenticated;

create or replace function public.stock_on_intervention_finalized()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if NEW.report_status = 'FINALIZED' and OLD.report_status is distinct from 'FINALIZED' then
    perform stock_deduct_for_intervention(NEW.id);
  end if;
  return NEW;
end;
$$;
revoke all on function public.stock_on_intervention_finalized() from public, anon, authenticated;
create trigger trg_interventions_stock_finalized
  after update of report_status on public.interventions
  for each row execute function public.stock_on_intervention_finalized();

-- Correction d'une pièce DÉJÀ déduite (quantité / pièce changée) : on
-- re-crédite l'ancienne déduction puis on déduit la nouvelle. Pièce encore
-- non déduite : aucun mouvement.
create or replace function public.stock_on_intervention_part_change()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if OLD.stock_deducted_qty is not null
     and (NEW.quantity is distinct from OLD.quantity or NEW.stock_item_id is distinct from OLD.stock_item_id) then
    if OLD.stock_item_id is not null then
      insert into stock_movements (stock_item_id, delta, reason, intervention_id, intervention_part_id, note)
      values (OLD.stock_item_id, OLD.stock_deducted_qty, 'annulation_intervention', OLD.intervention_id, OLD.id, 'Correction après validation');
    end if;
    if NEW.stock_item_id is not null then
      insert into stock_movements (stock_item_id, delta, reason, intervention_id, intervention_part_id, note)
      values (NEW.stock_item_id, -coalesce(NEW.quantity, 0), 'intervention', NEW.intervention_id, NEW.id, 'Correction après validation');
      NEW.stock_deducted_qty := coalesce(NEW.quantity, 0);
    else
      NEW.stock_deducted_qty := null;
    end if;
  end if;
  return NEW;
end;
$$;
revoke all on function public.stock_on_intervention_part_change() from public, anon, authenticated;
create trigger trg_intervention_parts_stock_update
  before update of quantity, stock_item_id on public.intervention_parts
  for each row execute function public.stock_on_intervention_part_change();

-- ========== 2) NOTIFICATIONS ADMIN ==========
-- Journal unique des notifications utiles (affiché dans HAYEVA Pro) ; une
-- notification avec push=true est envoyée sur les appareils de
-- l'administrateur (Edge Function admin-push). dedupe_key unique : jamais
-- deux fois la même notification (rappels, webhooks rejoués…).
create table if not exists public.admin_notifications (
  id uuid primary key default gen_random_uuid(),
  kind text not null check (kind in ('new_request', 'client_reschedule', 'client_cancel', 'quote_accepted', 'payment', 'stock_low', 'reminder')),
  title text not null,
  body text,
  url text,
  booking_id uuid references public.bookings(id) on delete cascade,
  dedupe_key text unique,
  push boolean not null default true,
  pushed_at timestamptz,
  read_at timestamptz,
  created_at timestamptz not null default now()
);
create index if not exists admin_notifications_created_idx on public.admin_notifications (created_at desc);
alter table public.admin_notifications enable row level security;
create policy "admin_notifications: admin read" on public.admin_notifications for select using (is_admin());
create policy "admin_notifications: admin update" on public.admin_notifications for update using (is_admin()) with check (is_admin());

create or replace function public.booking_contact_name(b public.bookings)
returns text
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(
    nullif(b.guest_name, ''),
    (select nullif(trim(concat_ws(' ', cp.first_name, cp.last_name)), '') from customer_profiles cp where cp.user_id = b.customer_user_id),
    (select pa.legal_name from professional_accounts pa where pa.id = b.professional_account_id),
    'Client');
$$;
revoke all on function public.booking_contact_name(public.bookings) from public, anon, authenticated;

create or replace function public.admin_notify(p_kind text, p_title text, p_body text, p_booking_id uuid, p_dedupe text, p_push boolean)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into admin_notifications (kind, title, body, booking_id, dedupe_key, push, url)
  values (p_kind, p_title, p_body, p_booking_id, p_dedupe, p_push,
          case when p_booking_id is not null then './?app=pro&booking=' || p_booking_id || '#espacePro' else './?app=pro#espacePro' end)
  on conflict (dedupe_key) do nothing;
end;
$$;
revoke all on function public.admin_notify(text, text, text, uuid, text, boolean) from public, anon, authenticated;

-- Envoi push (asynchrone) des notifications push=true.
create or replace function public.admin_notifications_dispatch()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare v_secret text;
begin
  if not NEW.push then return NEW; end if;
  begin
    select decrypted_secret into v_secret from vault.decrypted_secrets where name = 'webhook_secret';
    perform net.http_post(
      url := 'https://hvlzdsuyhrhaflwutwml.supabase.co/functions/v1/admin-push',
      headers := jsonb_build_object('Content-Type', 'application/json', 'Authorization', 'Bearer ' || v_secret),
      body := jsonb_build_object('notification_id', NEW.id)
    );
  exception when others then null;
  end;
  return NEW;
end;
$$;
revoke all on function public.admin_notifications_dispatch() from public, anon, authenticated;
create trigger trg_admin_notifications_dispatch
  after insert on public.admin_notifications
  for each row execute function public.admin_notifications_dispatch();

-- Réservations : demande / modification / annulation par le client.
-- (push=false : le push de ces 3 événements est déjà envoyé par
-- notify-admin-booking / notify-booking-change — pas de doublon.)
create or replace function public.notify_admin_booking_events()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_name text := booking_contact_name(NEW);
  v_when text := to_char(NEW.date, 'DD/MM/YYYY') || ' à ' || to_char(NEW.start_time, 'HH24:MI');
begin
  if tg_op = 'INSERT' then
    if NEW.status = 'PENDING' then
      perform admin_notify('new_request', 'Nouvelle demande de RDV', v_name || ' — ' || v_when, NEW.id, 'new_request:' || NEW.id, false);
    end if;
    return NEW;
  end if;
  if NEW.status = 'CANCELLED' and OLD.status is distinct from 'CANCELLED' and NEW.cancelled_by = 'customer' then
    perform admin_notify('client_cancel', 'RDV annulé par le client', v_name || ' — ' || to_char(OLD.date, 'DD/MM/YYYY') || ' à ' || to_char(OLD.start_time, 'HH24:MI'), NEW.id, 'client_cancel:' || NEW.id, false);
  elsif (NEW.date is distinct from OLD.date or NEW.start_time is distinct from OLD.start_time)
        and NEW.status in ('PENDING', 'CONFIRMED') and not is_admin() and auth.uid() is not null then
    perform admin_notify('client_reschedule', 'RDV modifié par le client', v_name || ' — ' || to_char(OLD.date, 'DD/MM/YYYY') || ' ' || to_char(OLD.start_time, 'HH24:MI') || ' → ' || v_when, NEW.id, 'client_reschedule:' || NEW.id || ':' || NEW.date || 'T' || NEW.start_time, false);
  end if;
  return NEW;
end;
$$;
revoke all on function public.notify_admin_booking_events() from public, anon, authenticated;
create trigger trg_notify_admin_booking_events
  after insert or update on public.bookings
  for each row execute function public.notify_admin_booking_events();

-- Devis accepté.
create or replace function public.notify_admin_quote_accepted()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if NEW.status = 'ACCEPTED' and OLD.status is distinct from 'ACCEPTED' then
    perform admin_notify('quote_accepted', 'Devis accepté', coalesce(NEW.reference, '') || coalesce(' — ' || NEW.title, '') || ' — ' || to_char(coalesce(NEW.total_cents, 0) / 100.0, 'FM999G999D00') || ' €', NEW.booking_id, 'quote_accepted:' || NEW.id, true);
  end if;
  return NEW;
end;
$$;
revoke all on function public.notify_admin_quote_accepted() from public, anon, authenticated;
create trigger trg_notify_admin_quote_accepted
  after update of status on public.quotes
  for each row execute function public.notify_admin_quote_accepted();

-- Paiement enregistré (facture passée à PAID).
alter table public.invoices add column if not exists paid_at timestamptz;
create or replace function public.notify_admin_invoice_paid()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if NEW.status = 'PAID' and (tg_op = 'INSERT' or OLD.status is distinct from 'PAID') then
    perform admin_notify('payment', 'Paiement enregistré', coalesce(NEW.reference, 'Facture') || ' — ' || to_char(coalesce(NEW.total_cents, 0) / 100.0, 'FM999G999D00') || ' €', null, 'payment:' || NEW.id, true);
  end if;
  return NEW;
end;
$$;
revoke all on function public.notify_admin_invoice_paid() from public, anon, authenticated;
create trigger trg_notify_admin_invoice_paid
  after insert or update of status on public.invoices
  for each row execute function public.notify_admin_invoice_paid();

-- Stock faible : uniquement au FRANCHISSEMENT du seuil (pas à chaque
-- mouvement sous le seuil).
create or replace function public.notify_admin_stock_low()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if NEW.min_quantity > 0 and NEW.quantity <= NEW.min_quantity
     and (OLD.quantity > OLD.min_quantity or OLD.min_quantity <= 0) then
    perform admin_notify('stock_low', 'Stock faible', NEW.name || coalesce(' (' || NEW.reference || ')', '') || ' — reste ' || trim(to_char(NEW.quantity, 'FM999999D99')) || ' ' || NEW.unit,
      null, 'stock_low:' || NEW.id || ':' || extract(epoch from now())::bigint, true);
  end if;
  return NEW;
end;
$$;
revoke all on function public.notify_admin_stock_low() from public, anon, authenticated;
create trigger trg_notify_admin_stock_low
  after update of quantity, min_quantity on public.stock_items
  for each row execute function public.notify_admin_stock_low();

-- Rappel d'intervention : 1 h avant chaque RDV confirmé (une seule fois).
create or replace function public.admin_intervention_reminders()
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  r record;
  n integer := 0;
  v_now timestamp := (now() at time zone 'Europe/Paris');
begin
  for r in
    select b.* from bookings b
     where b.status = 'CONFIRMED'
       and (b.date + b.start_time) > v_now
       and (b.date + b.start_time) <= v_now + interval '60 minutes'
  loop
    perform admin_notify('reminder', 'Rappel : intervention à ' || to_char(r.start_time, 'HH24:MI'),
      booking_contact_name(r) || coalesce(' — ' || (select name from services where id = r.service_id), ''),
      r.id, 'reminder:' || r.id || ':' || r.date || 'T' || r.start_time, true);
    n := n + 1;
  end loop;
  return n;
end;
$$;
revoke all on function public.admin_intervention_reminders() from public, anon, authenticated;
select cron.schedule('hayeva-admin-intervention-reminders', '*/10 * * * *', 'select public.admin_intervention_reminders();');

-- ========== 3) INFORMATIONS ENTREPRISE ==========
-- Une seule ligne (id = 1). Alimente devis/factures/documents. Tant que
-- les champs obligatoires ne sont pas complets, la facturation définitive
-- reste indisponible (company_billing_ready() = false). Aucune valeur n'est
-- pré-remplie : rien n'est inventé.
create table if not exists public.company_settings (
  id integer primary key default 1 check (id = 1),
  legal_name text,
  trade_name text,
  owner_name text,
  address_line1 text,
  address_line2 text,
  postal_code text,
  city text,
  siren text,
  siret text,
  vat_regime text check (vat_regime in ('franchise_base', 'assujetti')),
  vat_number text,
  insurance_company text,
  insurance_contract_number text,
  insurance_coverage text,
  mediator_name text,
  mediator_contact text,
  phone text,
  email text,
  website text,
  updated_at timestamptz not null default now()
);
alter table public.company_settings enable row level security;
create policy "company_settings: admin all" on public.company_settings for all using (is_admin()) with check (is_admin());
insert into public.company_settings (id) values (1) on conflict (id) do nothing;

create or replace function public.company_billing_ready()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select coalesce((
    select nullif(trim(coalesce(legal_name, trade_name, '')), '') is not null
       and nullif(trim(coalesce(owner_name, '')), '') is not null
       and nullif(trim(coalesce(address_line1, '')), '') is not null
       and nullif(trim(coalesce(postal_code, '')), '') is not null
       and nullif(trim(coalesce(city, '')), '') is not null
       and coalesce(siret, '') ~ '^[0-9]{14}$'
       and vat_regime is not null
       and (vat_regime = 'franchise_base' or nullif(trim(coalesce(vat_number, '')), '') is not null)
       and nullif(trim(coalesce(insurance_company, '')), '') is not null
       and nullif(trim(coalesce(insurance_contract_number, '')), '') is not null
       and nullif(trim(coalesce(mediator_name, '')), '') is not null
    from company_settings where id = 1), false);
$$;
revoke all on function public.company_billing_ready() from public, anon;
grant execute on function public.company_billing_ready() to authenticated;

-- Facture "définitive" (ISSUED/PAID) impossible tant que les informations
-- entreprise sont incomplètes — garde-fou côté serveur, pas seulement dans
-- l'interface.
create or replace function public.guard_invoice_billing_ready()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if NEW.status in ('ISSUED', 'PAID') and not company_billing_ready() then
    if tg_op = 'INSERT' then
      raise exception 'Facturation définitive indisponible — informations entreprise à compléter.';
    elsif OLD.status not in ('ISSUED', 'PAID') then
      raise exception 'Facturation définitive indisponible — informations entreprise à compléter.';
    end if;
  end if;
  return NEW;
end;
$$;
revoke all on function public.guard_invoice_billing_ready() from public, anon, authenticated;
create trigger trg_guard_invoice_billing_ready
  before insert or update of status on public.invoices
  for each row execute function public.guard_invoice_billing_ready();

-- ========== 4) Déplacement par l'admin : e-mail au client uniquement ==========
create or replace function public.admin_reschedule_booking(p_booking_id uuid, p_date date, p_start_time time without time zone)
returns table(booking_id uuid, reference text, date date, start_time time without time zone)
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_booking bookings%rowtype;
  v_secret text;
begin
  if not is_admin() then
    raise exception 'Accès réservé à l''administration.';
  end if;

  select * into v_booking from bookings where id = p_booking_id;
  if not found then
    raise exception 'Réservation introuvable.';
  end if;

  if v_booking.status not in ('PENDING', 'CONFIRMED', 'IN_PROGRESS') then
    raise exception 'Ce rendez-vous ne peut plus être déplacé.';
  end if;

  perform check_calendar_block_conflict(p_date, p_start_time, v_booking.service_duration_minutes);

  begin
    update bookings
    set date = p_date, start_time = p_start_time, updated_at = now()
    where id = p_booking_id;
  exception
    when exclusion_violation then
      raise exception 'Ce créneau est déjà occupé par une autre réservation confirmée.';
  end;

  begin
    select decrypted_secret into v_secret from vault.decrypted_secrets where name = 'webhook_secret';
    perform net.http_post(
      url := 'https://hvlzdsuyhrhaflwutwml.supabase.co/functions/v1/notify-booking-change',
      headers := jsonb_build_object('Content-Type', 'application/json', 'Authorization', 'Bearer ' || v_secret),
      body := jsonb_build_object(
        'event', 'rescheduled',
        'by', 'admin',
        'booking_id', p_booking_id,
        'old_date', v_booking.date,
        'old_start_time', v_booking.start_time,
        'new_date', p_date,
        'new_start_time', p_start_time
      )
    );
  exception
    when others then
      null;
  end;

  return query select p_booking_id, v_booking.reference, p_date, p_start_time;
end;
$function$;
