-- V2 phases 1/24 — Chiffres clés du tableau de bord (admin uniquement).
-- CA encaissé = factures PAID (total − remboursé), datées par paid_at
-- (fuseau Europe/Paris). Encours = factures ISSUED − paiements partiels.

create or replace function public.admin_finance_kpis()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_today date := (now() at time zone 'Europe/Paris')::date;
  v jsonb;
begin
  if not is_admin() then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  select jsonb_build_object(
    'revenue_month_cents', coalesce((select sum(coalesce(total_cents, 0) - coalesce(refunded_cents, 0)) from invoices
        where status = 'PAID' and date_trunc('month', paid_at at time zone 'Europe/Paris') = date_trunc('month', now() at time zone 'Europe/Paris')), 0),
    'revenue_year_cents', coalesce((select sum(coalesce(total_cents, 0) - coalesce(refunded_cents, 0)) from invoices
        where status = 'PAID' and date_trunc('year', paid_at at time zone 'Europe/Paris') = date_trunc('year', now() at time zone 'Europe/Paris')), 0),
    'outstanding_cents', coalesce((select sum(coalesce(i.total_cents, 0) - coalesce((select sum(p.amount_cents) from invoice_payments p where p.invoice_id = i.id), 0))
        from invoices i where i.status = 'ISSUED'), 0),
    'overdue_count', (select count(*) from invoices where status = 'ISSUED' and due_date < v_today),
    'quotes_pending_count', (select count(*) from quotes where status = 'SENT'),
    'quotes_pending_cents', coalesce((select sum(total_cents) from quotes where status = 'SENT'), 0),
    'quote_conversion_pct', (select case when count(*) = 0 then null
        else round(100.0 * count(*) filter (where status = 'ACCEPTED') / count(*)) end
        from quotes where sent_at >= now() - interval '90 days' and status in ('SENT', 'ACCEPTED', 'REFUSED', 'EXPIRED')),
    'maintenance_due_30d', (select count(*) from customer_equipment e
        where e.maintenance_reminders_enabled
          and public.equipment_next_maintenance_due(e) between v_today - 60 and v_today + 30)
  ) into v;
  return v;
end;
$$;
revoke all on function public.admin_finance_kpis() from public, anon;
grant execute on function public.admin_finance_kpis() to authenticated;
