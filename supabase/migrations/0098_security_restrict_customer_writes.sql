-- SÉCURITÉ — écritures directes réservées à l'administration.
-- Certaines policies « FOR ALL » (lecture + écriture) donnaient aux clients
-- particuliers / professionnels le droit de créer, modifier ou supprimer :
--   * leurs factures (ex. insérer une facture « payée » → validation
--     frauduleuse d'une prime de parrainage, ou supprimer une facture) ;
--   * les interventions / comptes rendus / photos / pièces de leurs RDV ;
--   * leurs réservations (suppression directe, hors parcours d'annulation).
-- Policies RESTRICTIVES (combinées en ET avec les existantes) : la lecture
-- autorisée n'est pas modifiée, seules les écritures exigent is_admin().
-- Le service_role (Edge Functions) n'est pas concerné (RLS contournée).
do $$
declare t text; c text;
begin
  foreach t in array array['invoices', 'interventions', 'intervention_items', 'intervention_photos', 'intervention_parts', 'intervention_anomalies'] loop
    foreach c in array array['insert', 'update', 'delete'] loop
      if not exists (select 1 from pg_policy where polrelid = ('public.' || t)::regclass and polname = t || ': admin only ' || c || ' (restrictive)') then
        if c = 'insert' then
          execute format('create policy %I on public.%I as restrictive for insert to anon, authenticated with check (is_admin())', t || ': admin only ' || c || ' (restrictive)', t);
        elsif c = 'update' then
          execute format('create policy %I on public.%I as restrictive for update to anon, authenticated using (is_admin()) with check (is_admin())', t || ': admin only ' || c || ' (restrictive)', t);
        else
          execute format('create policy %I on public.%I as restrictive for delete to anon, authenticated using (is_admin())', t || ': admin only ' || c || ' (restrictive)', t);
        end if;
      end if;
    end loop;
  end loop;
  -- Réservations : suppression réservée à l'administration (le client annule
  -- via cancel_own_booking, qui conserve l'historique).
  if not exists (select 1 from pg_policy where polrelid = 'public.bookings'::regclass and polname = 'bookings: admin only delete (restrictive)') then
    create policy "bookings: admin only delete (restrictive)" on public.bookings as restrictive for delete to anon, authenticated using (is_admin());
  end if;
end $$;
