-- ============================================================
-- Correctif — recompute_all_supplier_sale_prices() échouait
-- ============================================================
-- Trouvé en testant réellement le moteur de marge TVA-consciente (tâche
-- 14) : "UPDATE requires a WHERE clause" — ce projet Supabase refuse tout
-- UPDATE sans clause WHERE dès qu'il est exécuté par un rôle non
-- superuser (le cas de toute RPC appelée par un admin authentifié), même
-- si l'update ne change réellement que via le trigger déclenché. Passait
-- inaperçu dans la migration elle-même (exécutée en tant que rôle
-- postgres via le CLI, non concerné par cette garde).
create or replace function recompute_all_supplier_sale_prices()
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_count integer;
begin
  if not is_admin() then
    raise exception 'Réservé aux administrateurs.';
  end if;
  update supplier_products set updated_at = updated_at where true;
  get diagnostics v_count = row_count;
  return v_count;
end;
$$;
revoke all on function recompute_all_supplier_sale_prices() from public;
grant execute on function recompute_all_supplier_sale_prices() to authenticated;
