-- Décision du propriétaire (08/10/2026) : le déplacement offert même hors
-- de la zone de 25 km reste réservé aux Packs Premium, conformément à
-- is_free_travel_pack() côté serveur. La mention est retirée des Packs
-- Confort (catalogue affiché par le site, la réservation et les espaces).
update public.service_packs set perks = '{}'
  where slug in ('clim-confort','chauffage-chaudiere-gaz-confort','chauffage-chaudiere-fioul-confort');
