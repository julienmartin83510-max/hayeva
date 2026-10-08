-- 0126 — Message unique et explicite du verrou de facturation définitive
-- (fonction d'émission + trigger de garde), sans changer leur logique.
do $$
declare
  f text;
  v_old text := 'Facturation définitive indisponible — informations entreprise à compléter.';
  v_new text := 'Complétez les informations légales de l''''entreprise avant d''''émettre une facture définitive.';
begin
  foreach f in array array['public.admin_issue_invoice(uuid, date)', 'public.guard_invoice_billing_ready()'] loop
    execute replace(pg_get_functiondef(f::regprocedure), v_old, v_new);
  end loop;
end $$;
