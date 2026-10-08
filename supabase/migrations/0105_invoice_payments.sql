-- V2 phases 5/6 — Paiements partiels et échéance des factures.
--
-- • invoice_payments : chaque encaissement (montant, moyen, date, note).
-- • admin_record_invoice_payment() : enregistre un acompte / règlement
--   partiel sur une facture émise ; quand le cumul atteint le total, la
--   facture passe en PAID par le même chemin qu'aujourd'hui (mêmes
--   déclencheurs : notification admin, parrainage).
-- • invoices.due_date : échéance facultative ; « En retard » est un état
--   calculé (ISSUED + échéance dépassée), la contrainte de statut existante
--   n'est pas modifiée. Aucun délai de paiement n'est imposé par défaut.

alter table public.invoices add column if not exists due_date date;

create table if not exists public.invoice_payments (
  id uuid primary key default gen_random_uuid(),
  invoice_id uuid not null references public.invoices(id) on delete cascade,
  amount_cents integer not null check (amount_cents > 0),
  method text not null check (method in ('virement', 'cheque', 'especes', 'carte', 'autre')),
  paid_on date not null default ((now() at time zone 'Europe/Paris')::date),
  note text,
  created_by uuid,
  created_at timestamptz not null default now()
);
create index if not exists invoice_payments_invoice_idx on public.invoice_payments(invoice_id);
alter table public.invoice_payments enable row level security;
create policy "invoice_payments: admin read" on public.invoice_payments for select to authenticated using (public.is_admin());

create or replace function public.admin_record_invoice_payment(
  p_invoice_id uuid, p_amount_cents integer, p_method text, p_paid_on date default null, p_note text default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_inv invoices;
  v_paid integer;
begin
  if not is_admin() then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  select * into v_inv from invoices where id = p_invoice_id for update;
  if not found then raise exception 'Facture introuvable.'; end if;
  if v_inv.status <> 'ISSUED' then raise exception 'Seule une facture émise peut recevoir un paiement.'; end if;
  if p_amount_cents is null or p_amount_cents <= 0 then raise exception 'Montant invalide.'; end if;
  if p_method not in ('virement', 'cheque', 'especes', 'carte', 'autre') then raise exception 'Moyen de paiement invalide.'; end if;
  select coalesce(sum(amount_cents), 0) into v_paid from invoice_payments where invoice_id = p_invoice_id;
  if v_paid + p_amount_cents > coalesce(v_inv.total_cents, 0) then
    raise exception 'Le montant dépasse le reste à payer (% €).', replace(to_char((coalesce(v_inv.total_cents, 0) - v_paid) / 100.0, 'FM999999990.00'), '.', ',');
  end if;
  insert into invoice_payments (invoice_id, amount_cents, method, paid_on, note, created_by)
  values (p_invoice_id, p_amount_cents, p_method, coalesce(p_paid_on, (now() at time zone 'Europe/Paris')::date), nullif(trim(p_note), ''), auth.uid());
  v_paid := v_paid + p_amount_cents;
  if v_paid >= coalesce(v_inv.total_cents, 0) then
    update invoices set status = 'PAID', paid_at = now() where id = p_invoice_id;
  end if;
  insert into audit_logs (actor_user_id, action, entity, entity_id) values (auth.uid(), 'invoice_payment_recorded', 'invoices', p_invoice_id);
  return jsonb_build_object('paid_cents', v_paid, 'remaining_cents', greatest(coalesce(v_inv.total_cents, 0) - v_paid, 0),
                            'status', case when v_paid >= coalesce(v_inv.total_cents, 0) then 'PAID' else 'ISSUED' end);
end;
$$;
revoke all on function public.admin_record_invoice_payment(uuid, integer, text, date, text) from public, anon;
grant execute on function public.admin_record_invoice_payment(uuid, integer, text, date, text) to authenticated;
