-- Finalisation V2/V3 — corrections d'accès détectées par l'audit.
--
-- 1. Les règles RLS des tables publiques (services, packs, contrats…)
--    appellent is_admin() / my_professional_account_ids() : le droit
--    d'exécution de ces fonctions avait été retiré au rôle anon hors
--    migration, ce qui faisait échouer (42501) les lectures des visiteurs
--    non connectés. Droit rétabli (elles renvoient false / vide pour anon).
grant execute on function public.is_admin() to anon;
grant execute on function public.my_client_id() to anon;
grant execute on function public.my_professional_account_ids() to anon;

-- 2. Vues publiques volontairement « security definer » (colonnes non
--    sensibles uniquement) : en mode security_invoker elles étaient vides
--    (zone de déplacement) ou refusées (assistant) pour les visiteurs.
alter view public.travel_settings_public set (security_invoker = false);
alter view public.ai_settings_public set (security_invoker = false);
grant select on public.travel_settings_public to anon, authenticated;
grant select on public.ai_settings_public to anon, authenticated;

-- 3. Devis / factures créés depuis HAYEVA Pro avec seulement client_id :
--    rattachement automatique au compte en ligne du client (clients.user_id)
--    pour qu'il les retrouve dans son espace (règles et fonctions existantes
--    inchangées). Aussi appliqué quand un client crée son compte plus tard.
create or replace function public.doc_attach_customer_account()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.customer_user_id is null and new.professional_account_id is null and new.client_id is not null then
    select user_id into new.customer_user_id from clients where id = new.client_id;
  end if;
  return new;
end;
$$;
revoke all on function public.doc_attach_customer_account() from public, anon, authenticated;
create trigger trg_quotes_attach_customer before insert or update of client_id on public.quotes
  for each row execute function public.doc_attach_customer_account();
create trigger trg_invoices_attach_customer before insert or update of client_id on public.invoices
  for each row execute function public.doc_attach_customer_account();

create or replace function public.client_account_linked_attach_docs()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.user_id is not null and old.user_id is distinct from new.user_id then
    perform set_config('app.bypass_quote_protect', 'on', true);
    update quotes set customer_user_id = new.user_id
     where client_id = new.id and customer_user_id is null and professional_account_id is null;
    perform set_config('app.bypass_quote_protect', '', true);
    -- Rattachement du compte uniquement (le contenu figé de la facture ne
    -- change pas) : autorisé même sur une facture émise (voir 0112).
    perform set_config('app.invoice_issue', 'on', true);
    update invoices set customer_user_id = new.user_id
     where client_id = new.id and customer_user_id is null and professional_account_id is null;
    perform set_config('app.invoice_issue', '', true);
  end if;
  return new;
end;
$$;
revoke all on function public.client_account_linked_attach_docs() from public, anon, authenticated;
create trigger trg_clients_link_docs after update of user_id on public.clients
  for each row execute function public.client_account_linked_attach_docs();

update quotes q set customer_user_id = c.user_id from clients c
 where q.client_id = c.id and c.user_id is not null and q.customer_user_id is null and q.professional_account_id is null;
update invoices i set customer_user_id = c.user_id from clients c
 where i.client_id = c.id and c.user_id is not null and i.customer_user_id is null and i.professional_account_id is null;

-- 4. Une facture en brouillon n'est jamais visible par le client.
alter policy "invoices: owner customer, owner pro, or admin" on public.invoices
  using (is_admin() or (status <> 'DRAFT' and ((customer_user_id = (select auth.uid())) or (professional_account_id in (select my_professional_account_ids())))));
