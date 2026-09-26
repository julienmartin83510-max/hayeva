-- ============================================================
-- Consignes de préparation avant intervention
-- ============================================================
-- Objectif : un client dont le rendez-vous est confirmé reçoit des
-- consignes de préparation adaptées à la prestation réellement réservée
-- (dégager l'accès, vider le meuble sous l'évier...), pour que le
-- technicien puisse intervenir immédiatement. Texte structuré, JAMAIS
-- généré par l'assistant IA (voir ai-assistant/index.ts, non modifié par
-- cette migration) : une correspondance fixe prestation -> catégorie de
-- consigne, éditable depuis l'administration sans toucher au code.
--
-- Modèle : une petite table de catégories (texte modifiable par l'admin),
-- et une colonne sur "services" qui pointe vers la catégorie applicable.
-- Un admin peut donc changer le TEXTE d'une consigne, l'activer/désactiver,
-- ou ajuster le texte générique par défaut — sans déploiement. Réaffecter
-- une prestation à une autre catégorie reste un changement de code
-- (non demandé), volontairement hors périmètre.

create table prep_instruction_categories (
  id uuid primary key default gen_random_uuid(),
  key text not null unique,
  label text not null,             -- nom lisible dans l'admin, jamais affiché au client
  instruction text not null,
  is_active boolean not null default true,
  is_default boolean not null default false, -- exactement une ligne à true : le repli générique
  sort_order integer not null default 0,
  updated_at timestamptz not null default now(),
  updated_by uuid references auth.users(id) on delete set null
);

-- Une seule consigne par défaut à la fois : un admin qui active
-- "is_default" sur une ligne désactive automatiquement les autres, plutôt
-- que de laisser un état incohérent (deux replis génériques) possible
-- depuis l'admin.
create or replace function enforce_single_default_prep_instruction()
returns trigger
language plpgsql
as $$
begin
  if new.is_default then
    update prep_instruction_categories set is_default = false
    where id <> new.id and is_default = true;
  end if;
  return new;
end;
$$;
create trigger trg_single_default_prep_instruction
  before insert or update on prep_instruction_categories
  for each row execute function enforce_single_default_prep_instruction();

alter table prep_instruction_categories enable row level security;
-- Lecture publique : aucune donnée sensible (juste un texte de préparation
-- déjà destiné à être montré au client, avant même la réservation dans le
-- tunnel). Écriture réservée à l'admin, même pattern que le reste du projet.
create policy "prep_instructions: public read" on prep_instruction_categories
  for select using (true);
create policy "prep_instructions: admin write" on prep_instruction_categories
  for insert with check (is_admin());
create policy "prep_instructions: admin update" on prep_instruction_categories
  for update using (is_admin()) with check (is_admin());
create policy "prep_instructions: admin delete" on prep_instruction_categories
  for delete using (is_admin());
grant select on table prep_instruction_categories to anon, authenticated;
grant insert, update, delete on table prep_instruction_categories to authenticated;

insert into prep_instruction_categories (key, label, instruction, is_default, sort_order) values
  ('generic_default', 'Consigne générique (repli par défaut)',
   'Merci de dégager et rendre facilement accessible l''équipement ou la zone concernée avant l''arrivée du technicien.',
   true, 0),
  ('clim_entretien', 'Climatisation — entretien',
   'Pour faciliter l''intervention, merci de rendre accessibles les unités de climatisation concernées avant l''arrivée du technicien. Dégagez les meubles, objets ou éléments pouvant gêner l''accès et prévoyez un accès à l''unité extérieure lorsqu''elle doit être contrôlée. Merci de ne pas démonter l''appareil vous-même avant notre arrivée.',
   false, 10),
  ('chauffage_chaudiere', 'Chauffage — entretien/accès chaudière',
   'Merci de dégager l''espace autour de la chaudière et de rendre l''appareil facilement accessible. Aucun meuble, carton ou objet ne doit empêcher l''ouverture de la chaudière et l''intervention du technicien.',
   false, 20),
  ('chauffage_radiateur', 'Chauffage — radiateur / dépannage général',
   'Merci de dégager l''accès au radiateur ou à l''équipement concerné et de retirer les objets ou meubles pouvant gêner l''intervention.',
   false, 30),
  ('plomberie_robinet', 'Plomberie — robinet évier/lavabo',
   'Merci de vider le meuble situé sous l''évier ou le lavabo avant l''intervention et de dégager l''accès aux arrivées d''eau et aux raccordements.',
   false, 40),
  ('plomberie_wc', 'Plomberie — WC (mécanisme, chasse d''eau, débouchage)',
   'Merci de dégager l''espace autour du WC et de permettre un accès facile au mécanisme et à l''arrivée d''eau.',
   false, 50),
  ('plomberie_douche_baignoire', 'Plomberie — douche / baignoire',
   'Merci de retirer les produits, tapis, meubles et objets situés autour de la zone d''intervention afin de laisser l''accès entièrement dégagé.',
   false, 60),
  ('plomberie_debouchage_evier', 'Plomberie — débouchage évier/lavabo',
   'Merci de vider entièrement le meuble sous l''évier ou le lavabo et de laisser les canalisations accessibles.',
   false, 70),
  ('multi_services', 'Entretien Multi-Services (plusieurs domaines)',
   'Cette intervention couvre plusieurs domaines. Merci de rendre accessibles la climatisation et/ou la chaudière concernées, ainsi que les équipements de plomberie à vérifier (évier, WC, arrivées d''eau) : dégagez les meubles ou objets qui pourraient gêner l''accès à chacun de ces éléments.',
   false, 80);

-- ------------------------------------------------------------
-- Rattachement des prestations existantes à une catégorie. NULL = repli
-- automatique sur la catégorie is_default ("generic_default") côté
-- affichage — c'est le cas des packs d'entretien (rattachés via leur
-- service parent ci-dessous, ils n'ont pas besoin de leur propre clé),
-- de "Devis gratuit", "Installation climatisation" et des Check Techniques
-- professionnels, dont le contenu réel de l'intervention n'est pas connu
-- à l'avance.
alter table services add column prep_instruction_key text references prep_instruction_categories(key) on update cascade;

update services set prep_instruction_key = 'clim_entretien' where slug = 'clim-entretien';
update services set prep_instruction_key = 'chauffage_chaudiere' where slug in (
  'chauffage-chaudiere-gaz', 'chauffage-chaudiere-fioul',
  'chauffage-circulateur', 'chauffage-vase', 'chauffage-purge', 'chauffage-pression'
);
update services set prep_instruction_key = 'chauffage_radiateur' where slug in ('chauffage-radiateur', 'chauffage-depannage');
update services set prep_instruction_key = 'plomberie_robinet' where slug = 'plomberie-robinet';
update services set prep_instruction_key = 'plomberie_wc' where slug in ('plomberie-wc-mecanisme', 'plomberie-chasse-eau', 'plomberie-debouchage-wc');
update services set prep_instruction_key = 'plomberie_douche_baignoire' where slug in (
  'plomberie-seche-serviette', 'plomberie-colonne-douche', 'plomberie-paroi-douche',
  'plomberie-receveur', 'plomberie-baignoire'
);
update services set prep_instruction_key = 'plomberie_debouchage_evier' where slug = 'plomberie-debouchage-evier';
update services set prep_instruction_key = 'multi_services' where slug = 'multi';
-- plomberie-depannage / plomberie-fuite : intervention trop variable pour
-- une consigne dédiée fiable -> repli générique (NULL), comme demandé pour
-- "les autres prestations".
