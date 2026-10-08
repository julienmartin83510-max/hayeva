-- PARRAINAGE — acceptation d'une demande « Devenir parrain » / apporteur :
-- la fiche client est retrouvée par e-mail uniquement (jamais par le seul
-- téléphone saisi dans un formulaire public), puis le parrain est activé.
create or replace function public.admin_set_business_application_status(p_id uuid, p_status text, p_note text default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare a referral_business_applications%rowtype; v_client uuid; v_first text; v_last text;
begin
  if not is_admin() then raise exception 'Accès réservé à l''administration.'; end if;
  if p_status not in ('RECEIVED', 'TO_VERIFY', 'APPROVED', 'REFUSED', 'SUSPENDED') then raise exception 'Statut invalide.'; end if;
  select * into a from referral_business_applications where id = p_id for update;
  if not found then raise exception 'Demande introuvable.'; end if;
  v_client := a.client_id;
  if p_status = 'APPROVED' then
    if a.applicant_type = 'individual' then
      v_first := a.first_name; v_last := a.last_name;
    else
      v_first := split_part(coalesce(a.contact_name, a.legal_name), ' ', 1);
      v_last := nullif(trim(substring(coalesce(a.contact_name, a.legal_name) from length(v_first) + 1)), '');
    end if;
    -- Rattachement par e-mail uniquement : un numéro de téléphone saisi dans
    -- une demande publique ne doit jamais désigner la fiche d'un autre client.
    if v_client is null then
      v_client := find_or_create_client(null, a.email, null, v_first, v_last, null);
      update clients set phone = a.phone where id = v_client and nullif(trim(coalesce(phone, '')), '') is null and a.phone is not null;
    end if;
    if exists (select 1 from referral_codes where client_id = v_client) then
      update referral_codes set participant_type = a.applicant_type, status = 'active', updated_at = now() where client_id = v_client;
    else
      insert into referral_codes (client_id, code, participant_type, status, created_by)
      values (v_client, generate_referral_code_for(v_client), a.applicant_type, 'active', auth.uid());
    end if;
  elsif p_status in ('REFUSED', 'SUSPENDED') and v_client is not null then
    perform admin_set_referrer_status(v_client, 'suspended');
  end if;
  update referral_business_applications set status = p_status, client_id = v_client,
         admin_note = case when nullif(trim(coalesce(p_note, '')), '') is not null then concat_ws(' | ', admin_note, p_note) else admin_note end,
         reviewed_by = auth.uid(), reviewed_at = now(),
         approved_at = case when p_status = 'APPROVED' then coalesce(approved_at, now()) else approved_at end,
         updated_at = now()
   where id = a.id;
  insert into referral_events (event, detail) values ('ADMIN_APPLICATION_' || p_status, jsonb_build_object('application_id', a.id, 'type', a.applicant_type, 'client_id', v_client, 'by', auth.uid()));
  return jsonb_build_object('ok', true, 'client_id', v_client, 'code', (select code from referral_codes where client_id = v_client));
end;
$$;
