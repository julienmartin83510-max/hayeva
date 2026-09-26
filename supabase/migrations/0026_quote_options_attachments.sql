-- ============================================================
-- Devis HAYEVA — options multiples, pièces jointes, versioning
-- ============================================================
-- Réutilise la table "quotes" déjà en place (0001_init.sql) : aucune table
-- dupliquée. Jusqu'ici "quotes" n'était qu'un squelette (montants globaux,
-- aucune interface admin réelle — l'onglet admin "Devis" existant liste en
-- réalité les RENDEZ-VOUS de type "devis gratuit", pas des lignes de cette
-- table). Cette migration ajoute ce qui manque pour un vrai devis avec
-- plusieurs solutions comparables, chacune avec ses photos/documents.
--
-- MODÈLE :
--   quotes (existant)              — un devis, un statut, un total figé.
--   quote_options (nouveau)        — 1..N solutions nommées librement dans
--                                     un devis ("Solution unique" si un seul
--                                     devis classique).
--   quote_attachments (nouveau)    — photos/PDF rattachés à une option.
--
-- VERSIONING ("un devis accepté doit rester figé") : pas de table
-- d'historique séparée. Un devis SENT/ACCEPTED n'est plus modifiable en
-- base (RLS ci-dessous, vérifié aussi côté admin) — pour le faire évoluer,
-- l'admin crée un NOUVEAU devis (version += 1, parent_quote_id = l'ancien),
-- jamais une réécriture. L'ancien reste visible tel quel dans l'historique
-- du client.

alter table quotes
  add column title text,
  add column selected_option_id uuid,
  add column version integer not null default 1,
  add column parent_quote_id uuid references quotes(id) on delete set null,
  add column sent_at timestamptz,
  add column accepted_at timestamptz;

create table quote_options (
  id uuid primary key default gen_random_uuid(),
  quote_id uuid not null references quotes(id) on delete cascade,
  label text not null,                    -- nom libre ("Robinet GROHE", "Solution économique"...), jamais imposé
  reference text,                         -- référence produit, facultative
  description text,
  supply_cents integer not null default 0,
  labor_cents integer not null default 0,
  total_cents integer not null default 0, -- = supply_cents + labor_cents, recalculé par trigger (jamais désynchronisé)
  sort_order integer not null default 0,
  created_at timestamptz not null default now()
);
create index quote_options_quote_idx on quote_options (quote_id);

alter table quotes
  add constraint quotes_selected_option_fk foreign key (selected_option_id)
    references quote_options(id) on delete set null;

create or replace function quote_option_recompute_total()
returns trigger
language plpgsql
as $$
begin
  new.total_cents := coalesce(new.supply_cents, 0) + coalesce(new.labor_cents, 0);
  return new;
end;
$$;
create trigger trg_quote_option_recompute_total
  before insert or update on quote_options
  for each row execute function quote_option_recompute_total();

-- Bucket Storage privé — créé ici (pas de bucket "quote-attachments"
-- existant, aucun bucket Storage n'est utilisé nulle part ailleurs dans ce
-- projet à ce jour). JAMAIS public : accès uniquement via les policies
-- storage.objects ci-dessous, jamais via une URL directe.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('quote-attachments', 'quote-attachments', false, 8388608, array[
  'image/jpeg', 'image/png', 'image/webp', 'application/pdf'
])
on conflict (id) do update set
  public = false,
  file_size_limit = 8388608,
  allowed_mime_types = array['image/jpeg', 'image/png', 'image/webp', 'application/pdf'];

create table quote_attachments (
  id uuid primary key default gen_random_uuid(),
  quote_id uuid not null references quotes(id) on delete cascade,
  quote_option_id uuid references quote_options(id) on delete cascade,
  storage_path text not null unique,     -- '<quote_id>/<uuid>.<ext>', jamais un chemin devinable/public
  file_type text not null check (file_type in ('image', 'pdf')),
  file_name text,                        -- nom d'origine, pour affichage uniquement
  created_at timestamptz not null default now()
);
create index quote_attachments_quote_idx on quote_attachments (quote_id);
create index quote_attachments_option_idx on quote_attachments (quote_option_id);

-- ============================================================
-- RLS — quotes : la policy "for all" existante (0001_init.sql) laissait le
-- client insérer/modifier ses propres lignes sans aucune restriction de
-- statut (aucun contrôle métier, juste la propriété). Resserrée ici : le
-- client ne peut plus QUE lire ses devis SENT/ACCEPTED/REFUSED/EXPIRED
-- (jamais un DRAFT en cours de préparation par l'admin) ; toute écriture
-- passe soit par l'admin (is_admin(), sans restriction), soit par les RPC
-- dédiées ci-dessous (select_quote_option / accept_quote), jamais par une
-- écriture directe du client — même patron que create_booking()/
-- reschedule_own_booking() pour les réservations.
-- ============================================================
drop policy if exists "quotes: owner customer, owner pro, or admin" on quotes;

create policy "quotes: admin full access" on quotes
  for all using (is_admin()) with check (is_admin());

create policy "quotes: owner customer or pro can read sent quotes" on quotes
  for select using (
    status <> 'DRAFT'
    and (
      customer_user_id = auth.uid()
      or professional_account_id in (select my_professional_account_ids())
    )
  );

alter table quote_options enable row level security;
create policy "quote_options: admin full access on draft or own quote" on quote_options
  for all using (is_admin()) with check (
    is_admin() and exists (
      select 1 from quotes q where q.id = quote_id and q.status = 'DRAFT'
    )
  );
-- Un devis déjà envoyé reste lisible avec ses options (pour l'affichage
-- client), jamais modifiable (voir policy ci-dessus, restreinte à DRAFT) —
-- l'admin doit créer une nouvelle version pour changer une option envoyée.
create policy "quote_options: admin read all" on quote_options
  for select using (is_admin());
create policy "quote_options: owner customer or pro can read" on quote_options
  for select using (
    exists (
      select 1 from quotes q where q.id = quote_id and q.status <> 'DRAFT'
      and (q.customer_user_id = auth.uid() or q.professional_account_id in (select my_professional_account_ids()))
    )
  );

alter table quote_attachments enable row level security;
create policy "quote_attachments: admin full access on draft" on quote_attachments
  for all using (is_admin()) with check (
    is_admin() and exists (
      select 1 from quotes q where q.id = quote_id and q.status = 'DRAFT'
    )
  );
create policy "quote_attachments: admin read all" on quote_attachments
  for select using (is_admin());
create policy "quote_attachments: owner customer or pro can read" on quote_attachments
  for select using (
    exists (
      select 1 from quotes q where q.id = quote_id and q.status <> 'DRAFT'
      and (q.customer_user_id = auth.uid() or q.professional_account_id in (select my_professional_account_ids()))
    )
  );

revoke all on table quote_options, quote_attachments from anon, authenticated;
grant select, insert, update, delete on table quote_options, quote_attachments to authenticated;
grant select on table quote_options, quote_attachments to anon;
revoke insert, update, delete on table quotes from anon, authenticated;
grant select, insert, update, delete on table quotes to authenticated;

-- ============================================================
-- STORAGE — accès par ligne quote_attachments, jamais par préfixe de
-- chemin deviné : un client ne peut lire un fichier que si une ligne
-- quote_attachments pointant vers ce storage_path appartient à un devis
-- qui est le sien. Écriture réservée à l'admin (upload se fait toujours
-- depuis l'espace admin dans ce projet, jamais depuis le client).
-- ============================================================
create policy "quote-attachments: admin full access" on storage.objects
  for all using (bucket_id = 'quote-attachments' and is_admin())
  with check (bucket_id = 'quote-attachments' and is_admin());

create policy "quote-attachments: owner customer or pro read" on storage.objects
  for select using (
    bucket_id = 'quote-attachments'
    and exists (
      select 1 from quote_attachments qa
      join quotes q on q.id = qa.quote_id
      where qa.storage_path = storage.objects.name
        and q.status <> 'DRAFT'
        and (q.customer_user_id = auth.uid() or q.professional_account_id in (select my_professional_account_ids()))
    )
  );

-- ============================================================
-- RPC — sélection d'une option par le client (jamais d'acceptation
-- automatique : voir accept_quote() séparée). Revérifie tout côté serveur,
-- jamais de confiance dans un id fourni par le navigateur seul.
-- ============================================================
create or replace function select_quote_option(p_quote_id uuid, p_option_id uuid)
returns table(quote_id uuid, total_cents integer)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_quote quotes%rowtype;
  v_option quote_options%rowtype;
begin
  select * into v_quote from quotes where id = p_quote_id;
  if not found then
    raise exception 'Devis introuvable.';
  end if;
  if v_quote.status <> 'SENT' then
    raise exception 'Ce devis ne peut plus être modifié.';
  end if;
  -- Vérification NULL-safe (jamais de "IN"/"NOT IN" avec une valeur
  -- potentiellement NULL : en SQL, NULL NOT IN (...) ne vaut ni vrai ni
  -- faux, ce qui laisserait passer un devis sans professional_account_id
  -- si on l'utilisait dans une condition d'exclusion).
  if not (
    coalesce(v_quote.customer_user_id = v_uid, false)
    or (v_quote.professional_account_id is not null and v_quote.professional_account_id in (select my_professional_account_ids()))
  ) then
    raise exception 'Ce devis ne vous appartient pas.';
  end if;

  select * into v_option from quote_options where id = p_option_id and quote_id = p_quote_id;
  if not found then
    raise exception 'Cette option ne fait pas partie de ce devis.';
  end if;

  update quotes
    set selected_option_id = v_option.id,
        subtotal_cents = v_option.total_cents,
        total_cents = v_option.total_cents + coalesce(travel_fee_cents, 0) - coalesce(discount_cents, 0)
    where id = p_quote_id;

  return query select p_quote_id, (v_option.total_cents + coalesce(v_quote.travel_fee_cents, 0) - coalesce(v_quote.discount_cents, 0));
end;
$$;
revoke all on function select_quote_option(uuid, uuid) from public;
grant execute on function select_quote_option(uuid, uuid) to authenticated;

-- ============================================================
-- RPC — acceptation du devis. Action séparée et délibérée (jamais liée à
-- la simple sélection d'une option) : exige qu'une option soit déjà
-- sélectionnée. Fige définitivement le devis (RLS quote_options/
-- quote_attachments bloque déjà toute modification admin hors DRAFT ; ceci
-- bloque en plus toute nouvelle sélection côté client).
-- ============================================================
create or replace function accept_quote(p_quote_id uuid)
returns table(quote_id uuid, status text, total_cents integer)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_quote quotes%rowtype;
begin
  select * into v_quote from quotes where id = p_quote_id;
  if not found then
    raise exception 'Devis introuvable.';
  end if;
  if v_quote.status <> 'SENT' then
    raise exception 'Ce devis ne peut plus être accepté.';
  end if;
  if not (
    coalesce(v_quote.customer_user_id = v_uid, false)
    or (v_quote.professional_account_id is not null and v_quote.professional_account_id in (select my_professional_account_ids()))
  ) then
    raise exception 'Ce devis ne vous appartient pas.';
  end if;
  if v_quote.selected_option_id is null then
    raise exception 'Merci de sélectionner une solution avant d''accepter le devis.';
  end if;

  update quotes set status = 'ACCEPTED', accepted_at = now() where id = p_quote_id;

  return query select p_quote_id, 'ACCEPTED'::text, v_quote.total_cents;
end;
$$;
revoke all on function accept_quote(uuid) from public;
grant execute on function accept_quote(uuid) to authenticated;
