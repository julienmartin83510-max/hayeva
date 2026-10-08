-- 0125 — Le client voit les photos générales (avant/après, sans point de
-- contrôle) de SES interventions validées — jamais celles d'un autre client.
create policy "intervention_photos: customer sees general photos of own finalized interventions"
  on public.intervention_photos for select to authenticated
  using (
    intervention_item_id is null
    and intervention_id in (
      select i.id from public.interventions i
        join public.bookings b on b.id = i.booking_id
       where i.report_status = 'FINALIZED' and b.customer_user_id = (select auth.uid())
    )
  );
