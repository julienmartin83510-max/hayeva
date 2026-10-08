-- Sécurité (finalisation V2/V3) — notes internes STRICTEMENT réservées à l'admin.
--
-- Avant : clients.notes était lisible par le client lui-même (règle
-- « clients: self read »), launch_campaign_entries.admin_note par le
-- propriétaire du rendez-vous, referral_payout_requests.admin_note par le
-- parrain — via une requête directe à l'API, même si l'interface ne les
-- affichait pas.
--
-- Après :
-- • admin_internal_notes (admin uniquement) contient les notes internes des
--   fiches clients ; les notes existantes y sont déplacées et clients.notes est
--   vidé. Un déclencheur redirige toute écriture future de clients.notes vers
--   cette table (aucun ancien chemin d'écriture ne peut réintroduire la fuite).
-- • launch_campaign_entries et referral_payout_requests : lecture directe
--   réservée à l'admin ; le client lit le statut de ses participations via la
--   fonction get_my_launch_entry_statuses() (sans la note), et ses demandes de
--   versement via get_my_ambassador() (déjà sans note).

create table if not exists public.admin_internal_notes (
  entity text not null check (entity in ('client')),
  entity_id uuid not null,
  note text not null check (length(note) <= 8000),
  updated_at timestamptz not null default now(),
  updated_by uuid,
  primary key (entity, entity_id)
);
alter table public.admin_internal_notes enable row level security;
create policy "admin_internal_notes: admin only" on public.admin_internal_notes for all to authenticated
  using (public.is_admin()) with check (public.is_admin());
revoke all on public.admin_internal_notes from anon;

insert into public.admin_internal_notes (entity, entity_id, note)
select 'client', id, notes from public.clients where nullif(trim(notes), '') is not null
on conflict (entity, entity_id) do update set note = excluded.note, updated_at = now();
update public.clients set notes = null where notes is not null;

create or replace function public.clients_redirect_internal_notes()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare v_existing text;
begin
  if nullif(trim(new.notes), '') is not null then
    select note into v_existing from admin_internal_notes where entity = 'client' and entity_id = new.id;
    insert into admin_internal_notes (entity, entity_id, note, updated_by)
    values ('client', new.id,
            case when v_existing is null or position(v_existing in new.notes) > 0 then new.notes
                 else v_existing || E'\n' || new.notes end,
            auth.uid())
    on conflict (entity, entity_id) do update set note = excluded.note, updated_at = now(), updated_by = excluded.updated_by;
  end if;
  new.notes := null;
  return new;
end;
$$;
revoke all on function public.clients_redirect_internal_notes() from public, anon, authenticated;
create trigger trg_clients_redirect_internal_notes before insert or update of notes on public.clients
  for each row execute function public.clients_redirect_internal_notes();

alter policy "launch_campaign_entries: owner read" on public.launch_campaign_entries using (public.is_admin());
alter policy "referral_payouts_select" on public.referral_payout_requests using (public.is_admin());

create or replace function public.get_my_launch_entry_statuses(p_booking_ids uuid[])
returns table (booking_id uuid, status text)
language sql
stable
security definer
set search_path = public
as $$
  select e.booking_id, e.status
    from launch_campaign_entries e
    join bookings b on b.id = e.booking_id
   where e.booking_id = any(p_booking_ids)
     and (b.customer_user_id = auth.uid() or b.professional_account_id in (select my_professional_account_ids()))
$$;
revoke all on function public.get_my_launch_entry_statuses(uuid[]) from public, anon;
grant execute on function public.get_my_launch_entry_statuses(uuid[]) to authenticated;
