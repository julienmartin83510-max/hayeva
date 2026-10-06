-- HAYEVA Pro : création d'un RDV directement par l'administrateur pour un
-- client de sa base (y compris un client sans e-mail, joignable par
-- téléphone — cas courant en dépannage).
-- 1) Politique d'insertion dédiée à l'administration (la politique publique
--    "create own or guest" exigeait un e-mail invité).
create policy "bookings: admin insert" on public.bookings for insert with check (is_admin());
-- 2) Un RDV invité doit avoir un nom ET un moyen de contact (e-mail OU
--    téléphone). Le parcours public, lui, exige toujours l'e-mail (politique
--    RLS "create own or guest" + RPC inchangées).
alter table public.bookings drop constraint if exists bookings_has_an_owner;
alter table public.bookings add constraint bookings_has_an_owner check (
  customer_user_id is not null
  or professional_account_id is not null
  or (guest_name is not null and (guest_email is not null or guest_phone is not null))
);
