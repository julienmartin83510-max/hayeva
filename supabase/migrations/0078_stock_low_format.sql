-- Format de quantité lisible dans la notification "Stock faible" (3 au lieu de "3.").
create or replace function public.notify_admin_stock_low()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if NEW.min_quantity > 0 and NEW.quantity <= NEW.min_quantity
     and (OLD.quantity > OLD.min_quantity or OLD.min_quantity <= 0) then
    perform admin_notify('stock_low', 'Stock faible', NEW.name || coalesce(' (' || NEW.reference || ')', '') || ' — reste ' || rtrim(rtrim(NEW.quantity::text, '0'), '.') || ' ' || NEW.unit,
      null, 'stock_low:' || NEW.id || ':' || extract(epoch from now())::bigint, true);
  end if;
  return NEW;
end;
$$;
