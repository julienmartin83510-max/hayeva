-- 0124 — « Terminé » uniquement après un compte rendu validé, et photos
-- générales d'intervention (avant/après) visibles par LEUR client.

create or replace function public.finalize_intervention_booking(p_booking_id uuid)
returns table(booking_id uuid, status text)
language plpgsql
security definer
set search_path = public
as $$
begin
  if not is_admin() then
    raise exception 'Accès réservé à l''administration.';
  end if;
  if not exists (select 1 from interventions i where i.booking_id = p_booking_id and i.report_status = 'FINALIZED') then
    raise exception 'Validez d''abord la fiche d''intervention (signatures) avant de terminer le rendez-vous.';
  end if;
  if not exists (select 1 from bookings b where b.id = p_booking_id and b.status in ('CONFIRMED', 'IN_PROGRESS', 'COMPLETED')) then
    raise exception 'Ce rendez-vous ne peut pas être marqué terminé dans son état actuel.';
  end if;

  perform set_config('app.allow_status_change', 'on', true);
  update bookings set status = 'COMPLETED', updated_at = now() where id = p_booking_id and bookings.status <> 'COMPLETED';
  perform set_config('app.allow_status_change', 'off', true);

  return query select p_booking_id, 'COMPLETED'::text;
end;
$$;

create policy "intervention-photos: owner customer read general"
  on storage.objects for select to authenticated
  using (
    bucket_id = 'intervention-photos'
    and exists (
      select 1 from public.intervention_photos ip
        join public.interventions i on i.id = ip.intervention_id
        join public.bookings b on b.id = i.booking_id
       where ip.storage_path = storage.objects.name
         and ip.intervention_item_id is null
         and i.report_status = 'FINALIZED'
         and b.customer_user_id = auth.uid()
    )
  );
