-- Réaligne le rayon de déplacement offert sur ce que le site annonce partout
-- (25 km autour de Fréjus). La valeur avait été ramenée à 20 km depuis le
-- formulaire admin après 0020, si bien qu'un client situé entre 20 et 25 km
-- se voyait facturer un déplacement présenté comme offert. Valeur validée par
-- le gérant le 08/10/2026. Les réservations existantes gardent leur propre
-- snapshot de tarif (colonnes sur bookings) : aucun effet rétroactif.
update travel_settings set included_radius_km = 25, updated_at = now() where id = true;
