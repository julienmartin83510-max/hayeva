-- Cagnotte : une écriture négative (utilisation, régularisation) échouait
-- toujours, car la contrainte « solde >= 0 » est vérifiée sur la ligne
-- proposée à l'INSERT (montant négatif) avant la résolution ON CONFLICT.
-- Mise à jour d'abord, insertion seulement si le solde n'existe pas encore.
create or replace function public.wallet_tx_apply_balance()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  update wallet_balances set balance_cents = balance_cents + NEW.amount_cents, updated_at = now()
   where client_id = NEW.client_id;
  if not found then
    insert into wallet_balances (client_id, balance_cents) values (NEW.client_id, NEW.amount_cents);
  end if;
  return NEW;
end $$;
