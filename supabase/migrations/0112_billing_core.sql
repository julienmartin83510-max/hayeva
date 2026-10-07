-- Finalisation facturation HAYEVA (V2/V3).
--
-- • Numérotation chronologique sans trou, par type et par année :
--   DEV-2026-0001 (devis, attribué à l'envoi), FAC-2026-0001 (facture,
--   attribué à l'émission), AV-2026-0001 (avoir). Un brouillon garde sa
--   référence provisoire.
-- • Lignes de facture (invoice_lines) avec TVA par ligne. En franchise en
--   base (company_settings.vat_regime = 'franchise_base') le taux est TOUJOURS
--   forcé à 0 : aucune TVA n'est jamais inventée. Le passage au régime
--   « assujetti » se fait par un seul réglage (default_vat_rate).
--   Les montants saisis sont les montants payés par le client (TTC) ; le HT et
--   la TVA sont calculés et figés à l'émission.
-- • Une facture émise est figée (montants, lignes, client, numéro) et ne peut
--   plus être supprimée ; la correction passe par un avoir (credit_notes).
-- • Création : depuis un devis accepté, depuis un rendez-vous terminé, ou à
--   vide pour un client de la base.

-- ---------------------------------------------------------------- réglages
alter table public.company_settings
  add column if not exists default_vat_rate numeric(5,2) check (default_vat_rate is null or (default_vat_rate >= 0 and default_vat_rate <= 30)),
  add column if not exists payment_terms text,
  add column if not exists quote_validity_days integer check (quote_validity_days is null or quote_validity_days between 1 and 365);

-- ------------------------------------------------------------ numérotation
create table if not exists public.document_counters (
  doc_type text not null check (doc_type in ('DEV', 'FAC', 'AV')),
  year integer not null,
  last_value integer not null default 0,
  primary key (doc_type, year)
);
alter table public.document_counters enable row level security;
create policy "document_counters: admin read" on public.document_counters for select to authenticated using (public.is_admin());

create or replace function public.next_document_number(p_type text)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_year integer := extract(year from (now() at time zone 'Europe/Paris'))::integer;
  v_next integer;
begin
  insert into document_counters (doc_type, year, last_value) values (p_type, v_year, 1)
  on conflict (doc_type, year) do update set last_value = document_counters.last_value + 1
  returning last_value into v_next;
  return p_type || '-' || v_year || '-' || lpad(v_next::text, 4, '0');
end;
$$;
revoke all on function public.next_document_number(text) from public, anon, authenticated;

-- ---------------------------------------------------------- factures : colonnes
alter table public.invoices
  add column if not exists booking_id uuid references public.bookings(id) on delete set null,
  add column if not exists issued_at timestamptz,
  add column if not exists total_ht_cents integer,
  add column if not exists total_vat_cents integer,
  add column if not exists vat_regime text,
  add column if not exists customer_snapshot jsonb,
  add column if not exists company_snapshot jsonb,
  add column if not exists notes text,
  add column if not exists cancelled_reason text;

create table if not exists public.invoice_lines (
  id uuid primary key default gen_random_uuid(),
  invoice_id uuid not null references public.invoices(id) on delete cascade,
  position integer not null default 0,
  kind text not null default 'prestation' check (kind in ('prestation', 'main_oeuvre', 'fourniture', 'deplacement', 'remise', 'autre')),
  label text not null check (length(label) between 1 and 300),
  description text,
  quantity numeric(10,2) not null default 1 check (quantity > 0),
  unit_ttc_cents integer not null,
  vat_rate numeric(5,2) not null default 0 check (vat_rate >= 0 and vat_rate <= 30),
  created_at timestamptz not null default now()
);
create index if not exists invoice_lines_invoice_idx on public.invoice_lines(invoice_id, position);
alter table public.invoice_lines enable row level security;
create policy "invoice_lines: admin full access" on public.invoice_lines for all to authenticated
  using (public.is_admin()) with check (public.is_admin());
create policy "invoice_lines: owner read issued" on public.invoice_lines for select to authenticated
  using (exists (select 1 from invoices i where i.id = invoice_lines.invoice_id and i.status <> 'DRAFT'
                  and (i.customer_user_id = (select auth.uid()) or i.professional_account_id in (select my_professional_account_ids()))));

-- Taux effectif : 0 en franchise en base (jamais de TVA inventée).
create or replace function public.billing_effective_vat_rate(p_rate numeric)
returns numeric
language sql
stable
security definer
set search_path = public
as $$
  select case when (select vat_regime from company_settings where id = 1) = 'assujetti' then coalesce(p_rate, 0) else 0 end
$$;

create or replace function public.invoice_lines_guard()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare v_status text;
begin
  select status into v_status from invoices where id = coalesce(new.invoice_id, old.invoice_id);
  -- v_status nul : facture parente en cours de suppression (brouillon) — autorisé.
  if v_status is not null and v_status <> 'DRAFT' and coalesce(current_setting('app.invoice_issue', true), '') <> 'on' then
    raise exception 'Facture émise : ses lignes ne peuvent plus être modifiées (créez un avoir).';
  end if;
  if tg_op = 'DELETE' then return old; end if;
  new.vat_rate := billing_effective_vat_rate(new.vat_rate);
  return new;
end;
$$;
revoke all on function public.invoice_lines_guard() from public, anon, authenticated;
create trigger trg_invoice_lines_guard before insert or update or delete on public.invoice_lines
  for each row execute function public.invoice_lines_guard();

-- Facture émise : figée, jamais supprimée.
create or replace function public.invoices_immutability_guard()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if tg_op = 'DELETE' then
    if old.status <> 'DRAFT' then
      raise exception 'Une facture émise ne peut pas être supprimée : créez un avoir.';
    end if;
    return old;
  end if;
  if old.status <> 'DRAFT' and coalesce(current_setting('app.invoice_issue', true), '') <> 'on' then
    if new.status = 'DRAFT' then raise exception 'Une facture émise ne peut pas redevenir un brouillon.'; end if;
    if new.status = 'CANCELLED' and old.status <> 'CANCELLED' and coalesce(current_setting('app.credit_note', true), '') <> 'on' then
      raise exception 'Une facture émise s''annule par un avoir (bouton « Créer un avoir »).';
    end if;
    if new.reference is distinct from old.reference or new.total_cents is distinct from old.total_cents
       or new.total_ht_cents is distinct from old.total_ht_cents or new.total_vat_cents is distinct from old.total_vat_cents
       or new.client_id is distinct from old.client_id or new.customer_user_id is distinct from old.customer_user_id
       or new.professional_account_id is distinct from old.professional_account_id
       or new.issued_at is distinct from old.issued_at or new.customer_snapshot is distinct from old.customer_snapshot then
      raise exception 'Facture émise : numéro, montants et client ne peuvent plus être modifiés (créez un avoir).';
    end if;
  end if;
  if old.status = 'DRAFT' and new.status in ('ISSUED', 'PAID') and coalesce(current_setting('app.invoice_issue', true), '') <> 'on' then
    raise exception 'Utilisez « Émettre la facture » pour attribuer un numéro définitif.';
  end if;
  return new;
end;
$$;
revoke all on function public.invoices_immutability_guard() from public, anon, authenticated;
create trigger trg_invoices_immutability before update or delete on public.invoices
  for each row execute function public.invoices_immutability_guard();

-- ----------------------------------------------------------- création
create or replace function public._invoice_new_draft(p_client_id uuid, p_customer uuid, p_pro uuid, p_quote uuid, p_booking uuid)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare v_id uuid;
begin
  insert into invoices (client_id, customer_user_id, professional_account_id, quote_id, booking_id, reference, status, total_cents)
  values (p_client_id, p_customer, p_pro, p_quote, p_booking,
          'BROUILLON-' || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 8)), 'DRAFT', 0)
  returning id into v_id;
  return v_id;
end;
$$;
revoke all on function public._invoice_new_draft(uuid, uuid, uuid, uuid, uuid) from public, anon, authenticated;

create or replace function public._invoice_recompute_draft(p_invoice_id uuid)
returns void
language sql
security definer
set search_path = public
as $$
  update invoices set total_cents = coalesce((select sum(round(quantity * unit_ttc_cents)) from invoice_lines where invoice_id = p_invoice_id), 0)
   where id = p_invoice_id and status = 'DRAFT';
$$;
revoke all on function public._invoice_recompute_draft(uuid) from public, anon, authenticated;

create or replace function public.invoice_lines_recompute()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  perform _invoice_recompute_draft(coalesce(new.invoice_id, old.invoice_id));
  return null;
end;
$$;
revoke all on function public.invoice_lines_recompute() from public, anon, authenticated;
create trigger trg_invoice_lines_recompute after insert or update or delete on public.invoice_lines
  for each row execute function public.invoice_lines_recompute();

create or replace function public.admin_create_invoice(p_source text, p_id uuid)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_inv uuid;
  v_rate numeric := (select default_vat_rate from company_settings where id = 1);
  q quotes;
  o quote_options;
  b bookings;
  v_existing uuid;
begin
  if not is_admin() then raise exception 'Accès réservé à l''administration.' using errcode = '42501'; end if;
  if p_source = 'quote' then
    select * into q from quotes where id = p_id;
    if not found then raise exception 'Devis introuvable.'; end if;
    if q.status <> 'ACCEPTED' then raise exception 'Seul un devis accepté peut être facturé.'; end if;
    select id into v_existing from invoices where quote_id = p_id and status <> 'CANCELLED' limit 1;
    if v_existing is not null then return v_existing; end if;
    v_inv := _invoice_new_draft(q.client_id, q.customer_user_id, q.professional_account_id, q.id, q.booking_id);
    select * into o from quote_options where id = q.selected_option_id;
    if not found then select * into o from quote_options where quote_id = q.id order by sort_order limit 1; end if;
    if o.id is not null then
      if coalesce(o.supply_cents, 0) > 0 then
        insert into invoice_lines (invoice_id, position, kind, label, description, unit_ttc_cents, vat_rate)
        values (v_inv, 1, 'fourniture', coalesce(nullif(o.label, ''), 'Fournitures'), o.description, o.supply_cents, coalesce(v_rate, 0));
      end if;
      if coalesce(o.labor_cents, 0) > 0 then
        insert into invoice_lines (invoice_id, position, kind, label, unit_ttc_cents, vat_rate)
        values (v_inv, 2, 'main_oeuvre', 'Main-d''œuvre' || coalesce(' — ' || nullif(q.title, ''), ''), o.labor_cents, coalesce(v_rate, 0));
      end if;
    end if;
    if coalesce(q.travel_fee_cents, 0) > 0 then
      insert into invoice_lines (invoice_id, position, kind, label, unit_ttc_cents, vat_rate) values (v_inv, 3, 'deplacement', 'Déplacement', q.travel_fee_cents, coalesce(v_rate, 0));
    end if;
    if coalesce(q.discount_cents, 0) > 0 then
      insert into invoice_lines (invoice_id, position, kind, label, unit_ttc_cents, vat_rate) values (v_inv, 4, 'remise', 'Remise', -q.discount_cents, coalesce(v_rate, 0));
    end if;
  elsif p_source = 'booking' then
    select * into b from bookings where id = p_id;
    if not found then raise exception 'Rendez-vous introuvable.'; end if;
    if b.status <> 'COMPLETED' then raise exception 'Seul un rendez-vous terminé peut être facturé.'; end if;
    select id into v_existing from invoices where booking_id = p_id and status <> 'CANCELLED' limit 1;
    if v_existing is not null then return v_existing; end if;
    v_inv := _invoice_new_draft(b.client_id, b.customer_user_id, b.professional_account_id, null, b.id);
    insert into invoice_lines (invoice_id, position, kind, label, description, unit_ttc_cents, vat_rate)
    values (v_inv, 1, 'prestation', coalesce((select name from services where id = b.service_id), 'Intervention'),
            'Intervention du ' || to_char(b.date, 'DD/MM/YYYY') || ' — réf. ' || b.reference, coalesce(b.service_price_cents, 0), coalesce(v_rate, 0));
    if coalesce(b.travel_fee_cents, 0) > 0 then
      insert into invoice_lines (invoice_id, position, kind, label, unit_ttc_cents, vat_rate) values (v_inv, 2, 'deplacement', 'Déplacement', b.travel_fee_cents, coalesce(v_rate, 0));
    end if;
    if coalesce(b.discount_cents, 0) + coalesce(b.referral_advantage_cents, 0) > 0 then
      insert into invoice_lines (invoice_id, position, kind, label, unit_ttc_cents, vat_rate)
      values (v_inv, 3, 'remise', 'Remise', -(coalesce(b.discount_cents, 0) + coalesce(b.referral_advantage_cents, 0)), coalesce(v_rate, 0));
    end if;
  elsif p_source = 'client' then
    if not exists (select 1 from clients where id = p_id) then raise exception 'Client introuvable.'; end if;
    v_inv := _invoice_new_draft(p_id, null, null, null, null);
  else
    raise exception 'Source de facture inconnue.';
  end if;
  insert into audit_logs (actor_user_id, action, entity, entity_id) values (auth.uid(), 'invoice_draft_created', 'invoices', v_inv);
  return v_inv;
end;
$$;
revoke all on function public.admin_create_invoice(text, uuid) from public, anon;
grant execute on function public.admin_create_invoice(text, uuid) to authenticated;

-- ------------------------------------------------------------- émission
create or replace function public.admin_issue_invoice(p_invoice_id uuid, p_due_date date default null)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  i invoices;
  v_ttc integer;
  v_ht integer;
  v_ref text;
  v_customer jsonb;
  co company_settings;
begin
  if not is_admin() then raise exception 'Accès réservé à l''administration.' using errcode = '42501'; end if;
  if not company_billing_ready() then raise exception 'Facturation définitive indisponible — informations entreprise à compléter.'; end if;
  select * into i from invoices where id = p_invoice_id for update;
  if not found then raise exception 'Facture introuvable.'; end if;
  if i.status <> 'DRAFT' then raise exception 'Cette facture est déjà émise.'; end if;
  if not exists (select 1 from invoice_lines where invoice_id = i.id) then raise exception 'Ajoutez au moins une ligne avant d''émettre la facture.'; end if;
  select * into co from company_settings where id = 1;
  perform set_config('app.invoice_issue', 'on', true);
  -- Taux recalculés au régime en vigueur (jamais de TVA en franchise).
  update invoice_lines set vat_rate = billing_effective_vat_rate(vat_rate) where invoice_id = i.id;
  select coalesce(sum(round(quantity * unit_ttc_cents)), 0),
         coalesce(sum(round(round(quantity * unit_ttc_cents) * 100 / (100 + vat_rate))), 0)
    into v_ttc, v_ht from invoice_lines where invoice_id = i.id;
  if v_ttc <= 0 then raise exception 'Le total de la facture doit être positif.'; end if;
  if i.client_id is not null then
    select jsonb_build_object('name', nullif(trim(concat_ws(' ', first_name, last_name)), ''), 'address', address, 'postal_code', postal_code, 'city', city, 'email', email, 'phone', phone, 'type', client_type)
      into v_customer from clients where id = i.client_id;
  elsif i.professional_account_id is not null then
    select jsonb_build_object('name', legal_name, 'siret', siret, 'type', 'professionnel') into v_customer from professional_accounts where id = i.professional_account_id;
  elsif i.customer_user_id is not null then
    select jsonb_build_object('name', nullif(trim(concat_ws(' ', cp.first_name, cp.last_name)), ''), 'email', p.email,
             'address', a.address, 'postal_code', a.postal_code, 'city', a.city, 'type', 'particulier')
      into v_customer
      from profiles p left join customer_profiles cp on cp.user_id = p.user_id
      left join lateral (select address, postal_code, city from customer_addresses where customer_user_id = p.user_id order by is_billing desc nulls last, is_default desc nulls last limit 1) a on true
     where p.user_id = i.customer_user_id;
  end if;
  v_ref := next_document_number('FAC');
  update invoices set
    reference = v_ref, status = 'ISSUED', issued_at = now(), due_date = coalesce(p_due_date, due_date),
    total_cents = v_ttc, total_ht_cents = v_ht, total_vat_cents = v_ttc - v_ht, vat_regime = co.vat_regime,
    customer_snapshot = v_customer,
    company_snapshot = jsonb_build_object('legal_name', co.legal_name, 'trade_name', co.trade_name, 'owner_name', co.owner_name, 'legal_form', co.legal_form,
      'address_line1', co.address_line1, 'address_line2', co.address_line2, 'postal_code', co.postal_code, 'city', co.city, 'siret', co.siret,
      'rcs_number', co.rcs_number, 'vat_regime', co.vat_regime, 'vat_number', co.vat_number, 'insurance_company', co.insurance_company,
      'insurance_contract_number', co.insurance_contract_number, 'insurance_coverage', co.insurance_coverage, 'mediator_name', co.mediator_name,
      'mediator_contact', co.mediator_contact, 'phone', co.phone, 'email', co.email, 'website', co.website, 'payment_terms', co.payment_terms)
  where id = i.id;
  perform set_config('app.invoice_issue', '', true);
  insert into audit_logs (actor_user_id, action, entity, entity_id) values (auth.uid(), 'invoice_issued', 'invoices', i.id);
  return v_ref;
end;
$$;
revoke all on function public.admin_issue_invoice(uuid, date) from public, anon;
grant execute on function public.admin_issue_invoice(uuid, date) to authenticated;

-- --------------------------------------------------------------- avoirs
create table if not exists public.credit_notes (
  id uuid primary key default gen_random_uuid(),
  reference text not null unique,
  invoice_id uuid not null references public.invoices(id) on delete restrict,
  amount_cents integer not null check (amount_cents > 0),
  amount_ht_cents integer not null,
  vat_cents integer not null,
  reason text not null check (length(trim(reason)) between 3 and 500),
  is_full boolean not null default false,
  created_at timestamptz not null default now(),
  created_by uuid
);
create index if not exists credit_notes_invoice_idx on public.credit_notes(invoice_id);
alter table public.credit_notes enable row level security;
create policy "credit_notes: admin read" on public.credit_notes for select to authenticated using (public.is_admin());
create policy "credit_notes: owner read" on public.credit_notes for select to authenticated
  using (exists (select 1 from invoices i where i.id = credit_notes.invoice_id
                  and (i.customer_user_id = (select auth.uid()) or i.professional_account_id in (select my_professional_account_ids()))));

create or replace function public.credit_notes_no_change()
returns trigger
language plpgsql
as $$
begin
  raise exception 'Un avoir émis ne peut être ni modifié ni supprimé.';
end;
$$;
create trigger trg_credit_notes_no_change before update or delete on public.credit_notes
  for each row execute function public.credit_notes_no_change();

create or replace function public.admin_create_credit_note(p_invoice_id uuid, p_amount_cents integer, p_reason text)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  i invoices;
  v_credited integer;
  v_ref text;
  v_ht integer;
  v_full boolean;
begin
  if not is_admin() then raise exception 'Accès réservé à l''administration.' using errcode = '42501'; end if;
  select * into i from invoices where id = p_invoice_id for update;
  if not found then raise exception 'Facture introuvable.'; end if;
  if i.status not in ('ISSUED', 'PAID') then raise exception 'Un avoir ne peut porter que sur une facture émise ou payée.'; end if;
  if nullif(trim(coalesce(p_reason, '')), '') is null or length(trim(p_reason)) < 3 then raise exception 'Indiquez le motif de l''avoir.'; end if;
  select coalesce(sum(amount_cents), 0) into v_credited from credit_notes where invoice_id = i.id;
  if p_amount_cents is null or p_amount_cents <= 0 or v_credited + p_amount_cents > i.total_cents then
    raise exception 'Montant invalide : il reste % € disponibles pour un avoir.', replace(to_char((i.total_cents - v_credited) / 100.0, 'FM999999990.00'), '.', ',');
  end if;
  v_full := v_credited + p_amount_cents = i.total_cents;
  v_ht := case when coalesce(i.total_cents, 0) > 0 and i.total_ht_cents is not null
               then round(p_amount_cents::numeric * i.total_ht_cents / i.total_cents) else p_amount_cents end;
  v_ref := next_document_number('AV');
  insert into credit_notes (reference, invoice_id, amount_cents, amount_ht_cents, vat_cents, reason, is_full, created_by)
  values (v_ref, i.id, p_amount_cents, v_ht, p_amount_cents - v_ht, trim(p_reason), v_full, auth.uid());
  -- Avoir total sur une facture non réglée : la facture est annulée (le
  -- numéro reste attribué et visible ; la trace est conservée).
  if v_full and i.status = 'ISSUED' then
    perform set_config('app.credit_note', 'on', true);
    update invoices set status = 'CANCELLED', cancelled_reason = 'Avoir ' || v_ref || ' : ' || trim(p_reason) where id = i.id;
    perform set_config('app.credit_note', '', true);
  end if;
  insert into audit_logs (actor_user_id, action, entity, entity_id) values (auth.uid(), 'credit_note_created', 'invoices', i.id);
  return v_ref;
end;
$$;
revoke all on function public.admin_create_credit_note(uuid, integer, text) from public, anon;
grant execute on function public.admin_create_credit_note(uuid, integer, text) to authenticated;

-- ------------------------------------------------------- devis : numéro
create or replace function public.quotes_assign_number()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.status = 'SENT' and (tg_op = 'INSERT' or old.status = 'DRAFT') and new.reference !~ '^DEV-[0-9]{4}-[0-9]{4,}$' then
    new.reference := next_document_number('DEV');
  end if;
  return new;
end;
$$;
revoke all on function public.quotes_assign_number() from public, anon, authenticated;
create trigger trg_quotes_assign_number before insert or update of status on public.quotes
  for each row execute function public.quotes_assign_number();

-- -------------------------------------------- document complet (PDF)
-- Données nécessaires au PDF d'un devis / d'une facture / d'un avoir, avec
-- contrôle d'accès : admin, ou propriétaire (client / pro) d'un document
-- non brouillon. Jamais de note interne.
create or replace function public.get_document_pdf_data(p_kind text, p_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_admin boolean := is_admin();
  q quotes; i invoices; cn credit_notes;
  v_company jsonb;
  v_customer jsonb;
  v_owner_ok boolean;
begin
  if v_uid is null then raise exception 'Connexion requise.' using errcode = '42501'; end if;
  select to_jsonb(c) - 'id' - 'updated_at' into v_company from company_settings c where id = 1;
  if p_kind = 'quote' then
    select * into q from quotes where id = p_id;
    if not found then raise exception 'Document introuvable.'; end if;
    v_owner_ok := q.status <> 'DRAFT' and (q.customer_user_id = v_uid or q.professional_account_id in (select my_professional_account_ids()));
    if not (v_admin or v_owner_ok) then raise exception 'Document introuvable.' using errcode = '42501'; end if;
    if q.client_id is not null then
      select jsonb_build_object('name', nullif(trim(concat_ws(' ', first_name, last_name)), ''), 'address', address, 'postal_code', postal_code, 'city', city) into v_customer from clients where id = q.client_id;
    elsif q.professional_account_id is not null then
      select jsonb_build_object('name', legal_name, 'siret', siret) into v_customer from professional_accounts where id = q.professional_account_id;
    elsif q.customer_user_id is not null then
      select jsonb_build_object('name', nullif(trim(concat_ws(' ', cp.first_name, cp.last_name)), ''), 'address', a.address, 'postal_code', a.postal_code, 'city', a.city)
        into v_customer from customer_profiles cp
        left join lateral (select address, postal_code, city from customer_addresses where customer_user_id = cp.user_id order by is_billing desc nulls last, is_default desc nulls last limit 1) a on true
       where cp.user_id = q.customer_user_id;
    end if;
    return jsonb_build_object('kind', 'quote', 'company', v_company, 'customer', coalesce(v_customer, '{}'::jsonb),
      'doc', to_jsonb(q),
      'options', coalesce((select jsonb_agg(to_jsonb(o) order by o.sort_order) from quote_options o where o.quote_id = q.id), '[]'::jsonb));
  elsif p_kind = 'invoice' or p_kind = 'credit_note' then
    if p_kind = 'credit_note' then
      select * into cn from credit_notes where id = p_id;
      if not found then raise exception 'Document introuvable.'; end if;
      select * into i from invoices where id = cn.invoice_id;
    else
      select * into i from invoices where id = p_id;
    end if;
    if i.id is null then raise exception 'Document introuvable.'; end if;
    v_owner_ok := i.status <> 'DRAFT' and (i.customer_user_id = v_uid or i.professional_account_id in (select my_professional_account_ids()));
    if not (v_admin or v_owner_ok) then raise exception 'Document introuvable.' using errcode = '42501'; end if;
    return jsonb_build_object('kind', p_kind,
      'company', coalesce(i.company_snapshot, v_company),
      'customer', coalesce(i.customer_snapshot, '{}'::jsonb),
      'doc', to_jsonb(i) - 'company_snapshot' - 'customer_snapshot',
      'credit_note', case when cn.id is not null then to_jsonb(cn) - 'created_by' else null end,
      'lines', coalesce((select jsonb_agg(to_jsonb(l) order by l.position, l.created_at) from invoice_lines l where l.invoice_id = i.id), '[]'::jsonb),
      'payments', coalesce((select jsonb_agg(jsonb_build_object('amount_cents', p.amount_cents, 'method', p.method, 'paid_on', p.paid_on) order by p.paid_on) from invoice_payments p where p.invoice_id = i.id), '[]'::jsonb),
      'credit_notes', coalesce((select jsonb_agg(jsonb_build_object('reference', c.reference, 'amount_cents', c.amount_cents, 'created_at', c.created_at, 'reason', c.reason) order by c.created_at) from credit_notes c where c.invoice_id = i.id), '[]'::jsonb));
  end if;
  raise exception 'Type de document inconnu.';
end;
$$;
revoke all on function public.get_document_pdf_data(text, uuid) from public, anon;
grant execute on function public.get_document_pdf_data(text, uuid) to authenticated;
