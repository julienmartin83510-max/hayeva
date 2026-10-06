-- HAYEVA Pro : devis/factures pour TOUT client de la base (y compris un
-- client sans compte en ligne, rattaché par clients.id). Avant, un devis
-- exigeait un compte particulier ou pro.
alter table public.quotes drop constraint if exists quotes_has_an_owner;
alter table public.quotes add constraint quotes_has_an_owner
  check (customer_user_id is not null or professional_account_id is not null or client_id is not null);
alter table public.invoices drop constraint if exists invoices_has_an_owner;
alter table public.invoices add constraint invoices_has_an_owner
  check (customer_user_id is not null or professional_account_id is not null or client_id is not null);
