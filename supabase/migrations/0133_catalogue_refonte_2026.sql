-- Refonte du catalogue HAYEVA (grille validée par le gérant le 08/10/2026).
--
-- • TVA : HAYEVA est assujettie, taux par défaut 20 %. Les prix du catalogue
--   restent des montants TTC (ce que paie le client) ; la facturation calcule
--   HT et TVA à l'émission (0112_billing_core).
-- • Nouveaux champs catalogue : includes (opérations comprises),
--   catalog_group (rubrique d'affichage), supply_included (fourniture
--   comprise ou non), photo_hint (photo recommandée / facultative).
-- • Prestations historiques : jamais supprimées. Celles remplacées par la
--   nouvelle grille sont mises à jour sur place (les réservations passées
--   gardent leur prix figé dans bookings.service_price_cents) ; celles absentes
--   de la grille passent « sur devis ».

-- ---------------------------------------------------------------- TVA
update company_settings set vat_regime = 'assujetti', default_vat_rate = 20, updated_at = now() where id = 1;
update quote_calc_settings set vat_applicable = true, vat_rate_percent = 20, updated_at = now() where id = true;

-- ---------------------------------------------------------- colonnes
alter table services
  add column if not exists includes text[] not null default '{}',
  add column if not exists catalog_group text,
  add column if not exists supply_included boolean not null default false,
  add column if not exists photo_hint text;

do $$ begin
  alter table services add constraint services_catalog_group_check check (catalog_group is null or catalog_group in
    ('petits-depannages','robinetterie','wc-sanitaires','fuites-evacuations','chauffe-eau','chauffage','climatisation'));
exception when duplicate_object then null; end $$;
do $$ begin
  alter table services add constraint services_photo_hint_check check (photo_hint is null or photo_hint in ('recommended','optional'));
exception when duplicate_object then null; end $$;

-- Textes communs (main-d'œuvre seule, déplacement, accessibilité, interventions multiples).
-- (textes communs : CTE _txt répétée dans chaque requête ci-dessous)

-- ------------------------------------------------- mises à jour sur place
update services s set name = v.name, description = v.descr, catalog_group = v.grp, booking_type = 'DIRECT_BOOKING',
  price_display_mode = v.mode, base_price_cents = v.price, duration_minutes = v.dur, includes = v.inc,
  photo_hint = v.photo, supply_included = false, is_active = true, updated_at = now()
from (values
  ('plomberie-depannage', 'Diagnostic plomberie', 'Recherche de la cause d''une panne ou d''un dysfonctionnement de plomberie, avec proposition de réparation chiffrée.', 'petits-depannages', 'FIXED', 7900, 45,
    array['Écoute du problème et inspection de l''installation','Recherche de la cause de la panne','Explication du diagnostic','Proposition de réparation chiffrée avant toute intervention'], 'diag', 'recommended'),
  ('chauffage-depannage', 'Diagnostic chauffage', 'Recherche de la cause d''une panne ou d''un dysfonctionnement de chauffage, avec proposition de réparation chiffrée.', 'chauffage', 'FIXED', 7900, 45,
    array['Écoute du problème et inspection de l''installation','Contrôle des organes accessibles du circuit','Explication du diagnostic','Proposition de réparation chiffrée avant toute intervention'], 'diag', 'optional'),
  ('plomberie-fuite', 'Diagnostic de fuite visible sans destruction', 'Localisation d''une fuite visible ou accessible, sans démolition. La réparation fait l''objet d''un chiffrage séparé.', 'fuites-evacuations', 'FROM', 9900, 45,
    array['Inspection des canalisations et raccords accessibles','Localisation de la fuite visible','Mise en sécurité (coupure d''eau) si nécessaire','Proposition de réparation chiffrée'], 'diag', 'recommended'),
  ('plomberie-robinet', 'Remplacement mitigeur évier', 'Dépose de l''ancien mitigeur d''évier et pose d''un mitigeur compatible.', 'robinetterie', 'FIXED', 10900, 60,
    array['Coupure de l''eau lorsque possible','Dépose du mitigeur existant','Pose d''un mitigeur compatible (fourni par vous ou facturé séparément)','Raccordements standards','Vérification de l''étanchéité'], 'std', 'optional'),
  ('plomberie-wc-mecanisme', 'Remplacement mécanisme de chasse d''eau', 'Remplacement du mécanisme de chasse d''eau d''un WC à réservoir apparent.', 'wc-sanitaires', 'FIXED', 10900, 45,
    array['Coupure de l''alimentation du WC','Dépose du mécanisme existant','Pose et réglage du nouveau mécanisme','Vérification de l''étanchéité et du fonctionnement'], 'std', 'optional'),
  ('plomberie-debouchage-evier', 'Débouchage de siphon accessible', 'Démontage, nettoyage et remontage d''un siphon accessible (évier, lavabo, douche).', 'fuites-evacuations', 'FIXED', 8900, 30,
    array['Démontage du siphon accessible','Nettoyage et retrait du bouchon','Remontage et vérification de l''étanchéité','Test d''écoulement'], 'std', 'optional'),
  ('plomberie-debouchage-wc', 'Débouchage manuel simple', 'Débouchage manuel d''un WC, d''un évier ou d''un lavabo sans matériel motorisé.', 'fuites-evacuations', 'FROM', 11900, 60,
    array['Débouchage manuel (ventouse, furet manuel)','Test d''écoulement','Conseils pour éviter un nouveau bouchon'], 'std', 'optional'),
  ('chauffage-circulateur', 'Remplacement circulateur', 'Remplacement du circulateur de chauffage par un modèle compatible.', 'chauffage', 'FROM', 20800, 90,
    array['Isolement et vidange partielle du circuit','Dépose du circulateur existant','Pose d''un circulateur compatible (fourni par vous ou facturé séparément)','Remise en eau, purge et contrôle du fonctionnement'], 'std', 'recommended')
) as v(slug, name, descr, grp, mode, price, dur, inc, condkey, photo)
where s.slug = v.slug;

-- Conditions et exclusions des prestations ci-dessus (diagnostics : montant
-- déductible de la réparation ; autres : main-d'œuvre seule).
with _txt as (select
  'Prix TTC main-d''œuvre, fourniture non comprise (vous pouvez fournir la pièce ou nous la facturons séparément, montant annoncé avant pose). Déplacement offert dans un rayon de 25 km autour de Fréjus ; au-delà, frais annoncés avant confirmation. Tarif valable pour un élément accessible, sans démontage de meuble, carrelage ou cloison. Plusieurs interventions lors d''une même visite : le prix des interventions supplémentaires vous est proposé et validé avant réalisation.'::text as cond_std,
  'Prix TTC. Déplacement offert dans un rayon de 25 km autour de Fréjus ; au-delà, frais annoncés avant confirmation. Montant déduit du prix de la réparation si vous la faites réaliser par HAYEVA à l''issue du diagnostic.'::text as cond_diag,
  'Prestation sur devis : le prix dépend de l''installation et de ce qui est constaté sur place. Un devis détaillé vous est remis et doit être accepté avant toute intervention.'::text as cond_quote,
  array['Fourniture des pièces et équipements','Modification importante des raccordements','Réparation de tuyauterie défectueuse','Travaux supplémentaires imprévus (proposés et validés avant réalisation)']::text[] as exc_std)
update services s set conditions = case when s.slug in ('plomberie-depannage','chauffage-depannage','plomberie-fuite') then t.cond_diag else t.cond_std end,
  excludes = case when s.slug in ('plomberie-depannage','chauffage-depannage','plomberie-fuite') then array['Réparation et fournitures (chiffrées séparément)']::text[] else t.exc_std end
from _txt t
where s.slug in ('plomberie-depannage','chauffage-depannage','plomberie-fuite','plomberie-robinet','plomberie-wc-mecanisme','plomberie-debouchage-evier','plomberie-debouchage-wc','chauffage-circulateur');

-- --------------------------------------- prestations passées « sur devis »
with _txt as (select
  'Prix TTC main-d''œuvre, fourniture non comprise (vous pouvez fournir la pièce ou nous la facturons séparément, montant annoncé avant pose). Déplacement offert dans un rayon de 25 km autour de Fréjus ; au-delà, frais annoncés avant confirmation. Tarif valable pour un élément accessible, sans démontage de meuble, carrelage ou cloison. Plusieurs interventions lors d''une même visite : le prix des interventions supplémentaires vous est proposé et validé avant réalisation.'::text as cond_std,
  'Prix TTC. Déplacement offert dans un rayon de 25 km autour de Fréjus ; au-delà, frais annoncés avant confirmation. Montant déduit du prix de la réparation si vous la faites réaliser par HAYEVA à l''issue du diagnostic.'::text as cond_diag,
  'Prestation sur devis : le prix dépend de l''installation et de ce qui est constaté sur place. Un devis détaillé vous est remis et doit être accepté avant toute intervention.'::text as cond_quote,
  array['Fourniture des pièces et équipements','Modification importante des raccordements','Réparation de tuyauterie défectueuse','Travaux supplémentaires imprévus (proposés et validés avant réalisation)']::text[] as exc_std)
update services s set booking_type = 'QUOTE_REQUEST', price_display_mode = 'QUOTE', base_price_cents = null, duration_minutes = null,
  catalog_group = v.grp,
  -- receveur / baignoire gardent leur réserve propre (faisabilité, assurance).
  conditions = case
    when s.slug in ('plomberie-receveur','plomberie-baignoire') and position(t.cond_quote in coalesce(s.conditions, '')) > 0 then s.conditions
    when s.slug in ('plomberie-receveur','plomberie-baignoire') then t.cond_quote || ' ' || coalesce(s.conditions, '')
    else t.cond_quote end,
  updated_at = now()
from _txt t, (values
  ('plomberie-chasse-eau','wc-sanitaires'), ('plomberie-seche-serviette','wc-sanitaires'), ('plomberie-colonne-douche','wc-sanitaires'),
  ('plomberie-paroi-douche','wc-sanitaires'), ('plomberie-receveur','wc-sanitaires'), ('plomberie-baignoire','wc-sanitaires'),
  ('chauffage-radiateur','chauffage'), ('chauffage-vase','chauffage'), ('chauffage-purge','chauffage'), ('chauffage-pression','chauffage')
) as v(slug, grp)
where s.slug = v.slug;

update services set catalog_group = 'chauffage' where slug in ('chauffage-chaudiere-gaz','chauffage-chaudiere-fioul');
update services set catalog_group = 'climatisation' where slug in ('clim-entretien','clim-installation');

-- ----------------------------------------------- nouvelles prestations
with _txt as (select
  'Prix TTC main-d''œuvre, fourniture non comprise (vous pouvez fournir la pièce ou nous la facturons séparément, montant annoncé avant pose). Déplacement offert dans un rayon de 25 km autour de Fréjus ; au-delà, frais annoncés avant confirmation. Tarif valable pour un élément accessible, sans démontage de meuble, carrelage ou cloison. Plusieurs interventions lors d''une même visite : le prix des interventions supplémentaires vous est proposé et validé avant réalisation.'::text as cond_std,
  'Prix TTC. Déplacement offert dans un rayon de 25 km autour de Fréjus ; au-delà, frais annoncés avant confirmation. Montant déduit du prix de la réparation si vous la faites réaliser par HAYEVA à l''issue du diagnostic.'::text as cond_diag,
  'Prestation sur devis : le prix dépend de l''installation et de ce qui est constaté sur place. Un devis détaillé vous est remis et doit être accepté avant toute intervention.'::text as cond_quote,
  array['Fourniture des pièces et équipements','Modification importante des raccordements','Réparation de tuyauterie défectueuse','Travaux supplémentaires imprévus (proposés et validés avant réalisation)']::text[] as exc_std)
insert into services (slug, category, customer_type, name, description, booking_type, price_display_mode, base_price_cents, duration_minutes,
  catalog_group, includes, excludes, conditions, photo_hint, supply_included, is_active, sort_order)
select v.slug, v.cat, 'particulier', v.name, v.descr,
  case when v.mode = 'QUOTE' then 'QUOTE_REQUEST' else 'DIRECT_BOOKING' end, v.mode, v.price, v.dur,
  v.grp, v.inc,
  case when v.mode = 'QUOTE' then '{}'::text[] when v.condkey = 'diag' then array['Réparation et fournitures (chiffrées séparément)']::text[] else t.exc_std end,
  case when v.mode = 'QUOTE' then t.cond_quote when v.condkey = 'diag' then t.cond_diag else t.cond_std end,
  v.photo, false, true, v.sort
from _txt t, (values
  -- Petits dépannages
  ('plomberie-mousseur','plomberie','Remplacement mousseur','Remplacement du mousseur (embout) d''un robinet entartré ou endommagé.','FIXED',5900,15,'petits-depannages',
    array['Dépose du mousseur existant','Pose d''un mousseur compatible','Contrôle du débit'],'std',null,10),
  ('plomberie-flexible-douche','plomberie','Remplacement flexible de douche','Remplacement d''un flexible de douche qui fuit ou est abîmé.','FIXED',5900,15,'petits-depannages',
    array['Dépose du flexible existant','Pose d''un flexible compatible avec joints neufs','Vérification de l''étanchéité'],'std',null,11),
  ('plomberie-joint','plomberie','Remplacement joint accessible','Remplacement d''un joint accessible sur un raccord ou un robinet qui fuit.','FIXED',6900,30,'petits-depannages',
    array['Coupure de l''eau lorsque possible','Démontage du raccord accessible','Remplacement du joint','Vérification de l''étanchéité'],'std','optional',12),
  ('plomberie-flexible-alimentation','plomberie','Remplacement flexible d''alimentation','Remplacement d''un flexible d''alimentation (robinet, WC, chauffe-eau) accessible.','FIXED',7900,30,'petits-depannages',
    array['Coupure de l''eau','Dépose du flexible existant','Pose d''un flexible compatible','Vérification de l''étanchéité'],'std','optional',13),
  ('plomberie-robinet-arret','plomberie','Remplacement robinet d''arrêt','Remplacement d''un robinet d''arrêt accessible qui fuit ou ne ferme plus.','FIXED',8900,45,'petits-depannages',
    array['Coupure de l''eau en amont','Dépose du robinet existant','Pose d''un robinet d''arrêt compatible','Remise en eau et vérification de l''étanchéité'],'std','recommended',14),
  ('plomberie-robinet-lave-linge','plomberie','Remplacement robinet de lave-linge','Remplacement du robinet d''alimentation d''un lave-linge ou lave-vaisselle.','FIXED',8900,30,'petits-depannages',
    array['Coupure de l''eau','Dépose du robinet existant','Pose d''un robinet compatible','Vérification de l''étanchéité'],'std',null,15),
  -- Robinetterie
  ('plomberie-mitigeur-lavabo','plomberie','Remplacement mitigeur lavabo','Dépose de l''ancien mitigeur de lavabo et pose d''un mitigeur compatible.','FIXED',9900,60,'robinetterie',
    array['Coupure de l''eau lorsque possible','Dépose du mitigeur existant','Pose d''un mitigeur compatible (fourni par vous ou facturé séparément)','Raccordements standards','Vérification de l''étanchéité'],'std','optional',20),
  ('plomberie-mitigeur-douche','plomberie','Remplacement mitigeur douche mural','Remplacement d''un mitigeur de douche mural sur entraxe standard.','FIXED',12900,60,'robinetterie',
    array['Coupure de l''eau','Dépose du mitigeur existant','Pose d''un mitigeur mural compatible (entraxe standard)','Vérification de l''étanchéité et du fonctionnement'],'std','recommended',22),
  ('plomberie-mitigeur-thermostatique','plomberie','Remplacement mitigeur thermostatique','Remplacement d''un mitigeur thermostatique de douche ou de baignoire.','FIXED',14900,75,'robinetterie',
    array['Coupure de l''eau','Dépose du mitigeur existant','Pose d''un mitigeur thermostatique compatible','Réglage de la température et vérification de l''étanchéité'],'std','recommended',23),
  -- WC et sanitaires
  ('plomberie-flotteur-wc','plomberie','Remplacement flotteur WC','Remplacement du robinet flotteur d''un réservoir de WC qui coule ou ne se remplit plus.','FIXED',8900,30,'wc-sanitaires',
    array['Coupure de l''alimentation du WC','Dépose du flotteur existant','Pose et réglage du nouveau flotteur','Vérification du remplissage et de l''étanchéité'],'std',null,30),
  -- Fuites et évacuations
  ('plomberie-siphon','plomberie','Remplacement siphon','Remplacement d''un siphon accessible (évier, lavabo, douche).','FIXED',8900,30,'fuites-evacuations',
    array['Dépose du siphon existant','Pose d''un siphon compatible','Vérification de l''étanchéité','Test d''écoulement'],'std',null,40),
  ('plomberie-debouchage-complexe','plomberie','Débouchage complexe','Bouchon profond, canalisation encastrée ou nécessitant du matériel spécifique.','QUOTE',null,null,'fuites-evacuations',
    '{}'::text[],'quote','recommended',43),
  ('plomberie-fuite-reparation','plomberie','Réparation de fuite simple accessible','Réparation d''une fuite accessible, chiffrée après diagnostic.','QUOTE',null,null,'fuites-evacuations',
    '{}'::text[],'quote','recommended',45),
  ('plomberie-fuite-encastree','plomberie','Recherche de fuite encastrée','Fuite non visible ou nécessitant des moyens de détection spécialisés. Réalisée uniquement si elle est possible avec les compétences et équipements de HAYEVA.','QUOTE',null,null,'fuites-evacuations',
    '{}'::text[],'quote','recommended',46),
  -- Chauffe-eau
  ('plomberie-diagnostic-chauffe-eau','plomberie','Diagnostic chauffe-eau électrique','Recherche de la cause d''une panne de chauffe-eau électrique (plus d''eau chaude, fuite, disjonction).','FIXED',7900,45,'chauffe-eau',
    array['Inspection du chauffe-eau et de son installation','Contrôle des organes accessibles','Explication du diagnostic','Proposition de réparation chiffrée avant toute intervention'],'diag','recommended',50),
  ('plomberie-groupe-securite','plomberie','Remplacement groupe de sécurité','Remplacement du groupe de sécurité d''un chauffe-eau.','FIXED',12900,60,'chauffe-eau',
    array['Coupure de l''eau et de l''alimentation électrique','Dépose du groupe de sécurité existant','Pose d''un groupe de sécurité compatible','Remise en eau et vérification de l''étanchéité'],'std','optional',51),
  ('plomberie-chauffe-eau-resistance','plomberie','Remplacement résistance ou thermostat de chauffe-eau','Remplacement d''une résistance ou d''un thermostat de chauffe-eau électrique, chiffré après diagnostic.','QUOTE',null,null,'chauffe-eau',
    '{}'::text[],'quote','recommended',52),
  -- Chauffage
  ('chauffage-purge-radiateurs','chauffage','Purge et contrôle des radiateurs','Purge de l''air des radiateurs et contrôle de la pression du circuit.','FROM',7900,45,'chauffage',
    array['Purge des radiateurs accessibles','Contrôle et ajustement de la pression du circuit','Vérification du bon chauffage de chaque radiateur'],'std',null,62),
  ('chauffage-fuite-radiateur','chauffage','Réparation de fuite sur radiateur','Fuite sur un radiateur ou son raccordement, chiffrée après diagnostic.','QUOTE',null,null,'chauffage',
    '{}'::text[],'quote','recommended',64),
  ('chauffage-robinet-radiateur','chauffage','Remplacement robinet de radiateur','Remplacement d''un robinet ou d''une tête thermostatique de radiateur, chiffré selon l''installation.','QUOTE',null,null,'chauffage',
    '{}'::text[],'quote','recommended',65)
) as v(slug, cat, name, descr, mode, price, dur, grp, inc, condkey, photo, sort)
on conflict (slug) do nothing;

-- Ordre d'affichage des prestations remplacées dans leur nouvelle rubrique.
update services set sort_order = v.sort from (values
  ('plomberie-depannage',5),('plomberie-robinet',21),('plomberie-wc-mecanisme',31),('plomberie-chasse-eau',32),
  ('plomberie-seche-serviette',33),('plomberie-colonne-douche',34),('plomberie-paroi-douche',35),('plomberie-receveur',36),('plomberie-baignoire',37),
  ('plomberie-debouchage-evier',41),('plomberie-debouchage-wc',42),('plomberie-fuite',44),
  ('chauffage-depannage',60),('chauffage-circulateur',61),('chauffage-radiateur',63),('chauffage-vase',66),('chauffage-purge',67),('chauffage-pression',68)
) as v(slug, sort) where services.slug = v.slug;

