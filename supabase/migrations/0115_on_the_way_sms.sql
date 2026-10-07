-- « Je suis en route » : SMS en plus de l'e-mail, dès qu'un fournisseur SMS
-- est configuré (secrets SMS_PROVIDER + identifiants, voir _shared/sms.ts).
-- Aucun fournisseur payant n'est activé automatiquement.
alter table public.booking_on_the_way
  add column if not exists sms_status text check (sms_status in ('sent','not_configured','failed','no_phone')),
  add column if not exists email_status text check (email_status in ('sent','failed','no_email'));
