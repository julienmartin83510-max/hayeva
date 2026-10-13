-- PROJET DE TEST UNIQUEMENT (hayeva-eva-test) — jamais en production.
-- Le premier compte créé ET déjà confirmé (tableau de bord Supabase :
-- Authentication > Add user > « Auto Confirm User ») devient automatiquement
-- l'administrateur de test, avec l'équipement fictif qui en dépend.
-- Garde-fous :
--   * refuse de s'installer si la base contient un client réel ;
--   * ne fait rien si un administrateur existe déjà (une seule promotion) ;
--   * ignore les inscriptions publiques non confirmées (e-mail à valider).
-- Les rendez-vous fictifs (posés le 12/10/2026) sont recalés sur le jour de
-- création du compte : « demain » contient toujours 3 rendez-vous fictifs.
-- Les fonctions d'e-mail, SMS et agenda ne sont pas déployées dans ce projet.
do $$ begin
  if exists (select 1 from public.clients where coalesce(email, '') !~* '@(test\.local|exemple\.test)$') then
    raise exception 'ARRÊT : base contenant des clients réels.';
  end if;
end $$;

create or replace function public._test_realign_seed_dates(p_today date default current_date)
returns int language plpgsql security definer set search_path = public as $$
declare d int := p_today - date '2026-10-12'; n int;
begin
  if d <= 0 then return 0; end if;
  update bookings set date = date + d + (case when extract(isodow from date + d) = 7 then 1 else 0 end)
   where guest_email like '%@exemple.test';
  get diagnostics n = row_count;
  return n;
end $$;
revoke all on function public._test_realign_seed_dates(date) from public, anon, authenticated;

create or replace function public._test_promote_first_admin()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.email_confirmed_at is null or exists (select 1 from profiles where global_role = 'admin') then
    return new;
  end if;
  insert into profiles (user_id, email, global_role) values (new.id, new.email, 'admin')
  on conflict (user_id) do update set global_role = 'admin';
  insert into customer_equipment (customer_user_id, client_id, equipment_type, brand, model, last_service_at, maintenance_reminders_enabled)
  select new.id, c.id, 'chaudiere_gaz', 'Saunier Duval', 'ThemaPlus', current_date - interval '11 months', false
    from clients c where c.email = 'paul.martin@exemple.test'
     and not exists (select 1 from customer_equipment e where e.client_id = c.id);
  perform _test_realign_seed_dates();
  return new;
end $$;
revoke all on function public._test_promote_first_admin() from public, anon, authenticated;

drop trigger if exists trg_test_promote_first_admin on auth.users;
create trigger trg_test_promote_first_admin after insert on auth.users
  for each row execute function public._test_promote_first_admin();
