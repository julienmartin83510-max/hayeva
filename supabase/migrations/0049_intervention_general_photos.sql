-- ============================================================
-- Photos générales de l'intervention (indépendantes d'un item de checklist).
-- ============================================================
-- Jusqu'ici intervention_photos.intervention_item_id était NOT NULL : une
-- photo ne pouvait être prise que via une ligne de checklist. Certaines
-- interventions (ex. plomberie "Remplacement mécanisme WC") utilisent la
-- checklist climatisation par défaut, sans item pertinent où accrocher une
-- photo avant/pendant/après générale du chantier — d'où le besoin d'une
-- photo rattachée directement à l'intervention.
--
-- PUREMENT ADDITIF : aucune ligne existante modifiée, aucun item retiré.
-- Les photos déjà liées à un intervention_item_id le restent à l'identique.
alter table intervention_photos
  add column if not exists intervention_id uuid references interventions(id) on delete cascade;

alter table intervention_photos
  alter column intervention_item_id drop not null;

alter table intervention_photos
  drop constraint if exists intervention_photos_owner_check;
alter table intervention_photos
  add constraint intervention_photos_owner_check check (
    (intervention_item_id is not null and intervention_id is null)
    or (intervention_item_id is null and intervention_id is not null)
  );

create index if not exists idx_intervention_photos_intervention on intervention_photos(intervention_id);

-- Étend l'accès pro/admin (déjà couvert par is_admin() en pratique) aux
-- photos générales rattachées directement à l'intervention. Le SELECT
-- client (visibilité par item) n'est pas étendu : les photos générales
-- prises pendant l'intervention restent internes à l'équipe HAYEVA, comme
-- avant l'ajout de cette fonctionnalité.
drop policy if exists "intervention_photos: pro or admin full access" on intervention_photos;
create policy "intervention_photos: pro or admin full access" on intervention_photos
  for all using (
    is_admin()
    or intervention_item_id in (
      select ii.id from intervention_items ii
      join interventions i on i.id = ii.intervention_id
      join bookings b on b.id = i.booking_id
      where b.professional_account_id in (select my_professional_account_ids())
    )
    or intervention_id in (
      select i.id from interventions i
      join bookings b on b.id = i.booking_id
      where b.professional_account_id in (select my_professional_account_ids())
    )
  ) with check (
    is_admin()
    or intervention_item_id in (
      select ii.id from intervention_items ii
      join interventions i on i.id = ii.intervention_id
      join bookings b on b.id = i.booking_id
      where b.professional_account_id in (select my_professional_account_ids())
    )
    or intervention_id in (
      select i.id from interventions i
      join bookings b on b.id = i.booking_id
      where b.professional_account_id in (select my_professional_account_ids())
    )
  );
