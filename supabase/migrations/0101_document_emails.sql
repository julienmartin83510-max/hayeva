-- E-mails automatiques des documents : devis envoyé (status → SENT) et
-- facture émise (status → ISSUED). Même mécanisme que les e-mails de
-- réservation : trigger AFTER → pg_net → Edge Function notify-document
-- (authentifiée par le secret de webhook du coffre). Journal + anti-doublon
-- dans document_emails (clé unique par document et par type d'envoi).

create table if not exists public.document_emails (
  id uuid primary key default gen_random_uuid(),
  doc_type text not null check (doc_type in ('quote', 'invoice')),
  doc_id uuid not null,
  email_type text not null check (email_type in ('quote_sent', 'invoice_issued')),
  status text not null default 'pending' check (status in ('pending', 'sent', 'failed', 'skipped')),
  recipient_email text,
  error_message text,
  dedupe_key text not null unique,
  sent_at timestamptz,
  created_at timestamptz not null default now()
);
create index if not exists document_emails_doc_idx on public.document_emails (doc_type, doc_id);
alter table public.document_emails enable row level security;
revoke all on public.document_emails from anon;
create policy "document_emails: admin read" on public.document_emails for select to authenticated using (public.is_admin());

create or replace function public.notify_document_email()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_secret text;
  v_type text;
begin
  if TG_TABLE_NAME = 'quotes' and NEW.status = 'SENT' and (TG_OP = 'INSERT' or OLD.status is distinct from 'SENT') then
    v_type := 'quote';
  elsif TG_TABLE_NAME = 'invoices' and NEW.status = 'ISSUED' and (TG_OP = 'INSERT' or OLD.status is distinct from 'ISSUED') then
    v_type := 'invoice';
  else
    return NEW;
  end if;
  select decrypted_secret into v_secret from vault.decrypted_secrets where name = 'webhook_secret';
  if v_secret is null then return NEW; end if;
  perform net.http_post(
    url := 'https://hvlzdsuyhrhaflwutwml.supabase.co/functions/v1/notify-document',
    headers := jsonb_build_object('Content-Type', 'application/json', 'Authorization', 'Bearer ' || v_secret),
    body := jsonb_build_object('type', v_type, 'id', NEW.id)
  );
  return NEW;
end;
$$;
revoke all on function public.notify_document_email() from public, anon, authenticated;

create trigger trg_notify_quote_sent after insert or update of status on public.quotes
  for each row execute function public.notify_document_email();

create trigger trg_notify_invoice_issued after insert or update of status on public.invoices
  for each row execute function public.notify_document_email();
