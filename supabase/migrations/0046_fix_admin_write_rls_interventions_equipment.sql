-- Correctif RLS : deux policies "for all" (0001_init.sql) autorisaient déjà
-- l'admin en lecture/USING (is_admin() y figurait) mais PAS en écriture —
-- leur clause WITH CHECK omettait is_admin(), ce qui bloquait tout insert/
-- update fait par l'administration sur ces deux tables. Repéré en testant
-- réellement le module Fiche d'intervention (0044) sur un vrai rendez-vous :
-- impossible pour l'admin d'enregistrer un équipement ou de finaliser une
-- fiche d'intervention avant ce correctif.
--
-- Comportement client/pro inchangé : leur propre clause WITH CHECK
-- (propriété du booking/de l'équipement) reste strictement identique, on
-- ajoute juste l'échappatoire admin qui manquait, symétrique de ce qui
-- existe déjà sur intervention_items/intervention_photos (0001_init.sql).

drop policy if exists "customer_equipment: self or admin" on customer_equipment;
create policy "customer_equipment: self or admin" on customer_equipment
  for all using (
    customer_user_id = auth.uid() or is_admin()
  ) with check (
    customer_user_id = auth.uid() or is_admin()
  );

drop policy if exists "interventions: via booking owner" on interventions;
create policy "interventions: via booking owner" on interventions
  for all using (
    is_admin()
    or booking_id in (
      select id from bookings
      where customer_user_id = auth.uid()
         or professional_account_id in (select my_professional_account_ids())
    )
  ) with check (
    is_admin()
    or booking_id in (
      select id from bookings
      where customer_user_id = auth.uid()
         or professional_account_id in (select my_professional_account_ids())
    )
  );
