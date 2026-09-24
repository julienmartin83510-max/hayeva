-- ============================================================
-- Réservations : plus aucune écriture directe par un client
-- Rôles : plus aucune auto-attribution de "professional" ou "admin"
-- ============================================================
-- Failles reproduites en local AVANT cette migration, avec un simple compte
-- particulier connecté et la clé publique du site (API REST Supabase) :
--   * INSERT direct dans bookings d'une réservation à 0 € déjà "CONFIRMED"
--     (la policy "bookings: create own or guest" l'autorisait, et
--     protect_booking_financial_fields() ne protège que les UPDATE) ;
--   * UPDATE direct de la date, de l'heure, de la prestation, du pack et de
--     l'adresse de sa propre réservation (seuls prix/statut/distance étaient
--     gelés par protect_booking_financial_fields()) ;
--   * DELETE définitif de sa propre réservation ;
--   * INSERT dans profiles avec global_role = 'professional' ;
--   * création directe d'un professional_accounts + professional_members
--     "owner" hors du parcours officiel create_professional_account().
--
-- Dépendances vérifiées (index.html + Edge Functions) avant modification :
--   * aucune écriture client sur bookings : les réservations sont créées
--     uniquement via create_booking() / create_guest_or_quote_booking()
--     (SECURITY DEFINER, non soumises à RLS) ; les seuls UPDATE directs sont
--     ceux du panneau Administration (status, admin_viewed_at), qui restent
--     autorisés à is_admin() ; aucun DELETE nulle part ;
--   * profiles : le seul INSERT client est celui de l'Espace Particulier
--     (global_role = 'customer') ; les comptes pro passent par
--     create_professional_account() (SECURITY DEFINER) ;
--   * professional_accounts / professional_members : aucun INSERT client
--     (lecture seule côté site, création via create_professional_account()).
--
-- Rejouable sans risque (idempotent).

-- ---------------------------------------------------------------------
-- 1. bookings — policies
-- ---------------------------------------------------------------------
-- INSERT : plus aucune policy. Toute création passe par les RPC serveur,
-- qui recalculent prix/durée/frais/statut et vérifient le créneau.
drop policy if exists "bookings: create own or guest" on bookings;

-- UPDATE : réservé à l'administrateur (changement de statut, "vu").
drop policy if exists "bookings: owner or admin update" on bookings;
drop policy if exists "bookings: admin update" on bookings;
create policy "bookings: admin update" on bookings
  for update using (is_admin()) with check (is_admin());

-- DELETE : réservé à l'administrateur. Un client ne supprime jamais une
-- réservation : une annulation passe par le statut CANCELLED (ligne
-- conservée, e-mail d'annulation déclenché par trg_notify_customer_status_change).
drop policy if exists "bookings: owner or admin delete" on bookings;
drop policy if exists "bookings: admin delete" on bookings;
create policy "bookings: admin delete" on bookings
  for delete using (is_admin());

-- La lecture ("bookings: owner or admin read") est inchangée : le client
-- continue de voir ses rendez-vous dans son Espace Client.

-- ---------------------------------------------------------------------
-- 2. bookings — garde-fou en base (défense en profondeur)
-- ---------------------------------------------------------------------
-- Indépendant des policies : même si une policy trop large était recréée
-- un jour par erreur, aucune écriture DIRECTE (INSERT / UPDATE / DELETE)
-- venant du navigateur (rôles anon / authenticated) n'est acceptée, sauf
-- pour un administrateur.
--
-- SECURITY INVOKER volontairement (pas de "security definer") : current_user
-- reflète alors le vrai contexte d'exécution :
--   * appel REST direct du navigateur         -> anon / authenticated -> bloqué
--   * RPC SECURITY DEFINER (create_booking(),
--     create_guest_or_quote_booking(), et toute
--     future fonction serveur comme un
--     reschedule_own_booking())               -> propriétaire (postgres) -> autorisé
--   * Edge Functions (service_role), SQL Editor,
--     actions ON DELETE SET NULL des clés
--     étrangères                               -> autorisé
-- Contrairement à protect_booking_financial_fields() (qui annule en
-- silence), ce trigger lève une erreur explicite.
create or replace function protect_booking_direct_writes()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if current_user in ('anon', 'authenticated') and not is_admin() then
    raise exception 'Modification directe d''une réservation interdite. Contactez HAYEVA pour modifier ou annuler un rendez-vous.'
      using errcode = '42501';
  end if;
  if tg_op = 'DELETE' then
    return old;
  end if;
  return new;
end;
$$;
revoke execute on function protect_booking_direct_writes() from public, anon, authenticated;

drop trigger if exists trg_protect_booking_direct_writes on bookings;
create trigger trg_protect_booking_direct_writes
  before insert or update or delete on bookings
  for each row execute function protect_booking_direct_writes();

-- ---------------------------------------------------------------------
-- 3. profiles — rôle global jamais auto-attribué
-- ---------------------------------------------------------------------
-- Avant : un utilisateur pouvait créer son profil avec
-- global_role = 'professional' directement (sans entreprise). Désormais :
--   * inscription particulier : INSERT direct limité à 'customer' ;
--   * inscription professionnelle : uniquement via create_professional_account()
--     (SECURITY DEFINER, crée entreprise + membre + profil de façon atomique) ;
--   * 'admin' : uniquement par un administrateur existant ou le SQL Editor.
drop policy if exists "profiles: self insert" on profiles;
drop policy if exists "profiles: self insert customer" on profiles;
create policy "profiles: self insert customer" on profiles
  for insert with check (user_id = auth.uid() and global_role = 'customer');

-- La policy d'UPDATE reste réservée à is_admin() ("profiles: admin update").
-- Garde-fou en base, même principe que pour bookings : depuis le navigateur,
-- un non-admin ne peut ni créer un profil autre que 'customer', ni changer
-- un global_role, ni réattribuer un profil à un autre utilisateur.
create or replace function protect_profile_role()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if current_user in ('anon', 'authenticated') and not is_admin() then
    if tg_op = 'INSERT' and new.global_role <> 'customer' then
      raise exception 'Rôle non autorisé.' using errcode = '42501';
    end if;
    if tg_op = 'UPDATE' and (new.global_role is distinct from old.global_role
                             or new.user_id is distinct from old.user_id) then
      raise exception 'Modification du rôle interdite.' using errcode = '42501';
    end if;
  end if;
  return new;
end;
$$;
revoke execute on function protect_profile_role() from public, anon, authenticated;

drop trigger if exists trg_protect_profile_role on profiles;
create trigger trg_protect_profile_role
  before insert or update on profiles
  for each row execute function protect_profile_role();

-- ---------------------------------------------------------------------
-- 4. Comptes professionnels — création uniquement via la RPC officielle
-- ---------------------------------------------------------------------
-- Ces deux policies permettaient à n'importe quel compte (même particulier)
-- de se créer une entreprise et de s'en déclarer "owner" hors du parcours
-- create_professional_account(). Le site n'utilise pas ce chemin direct
-- (la RPC SECURITY DEFINER n'est pas soumise à RLS) : suppression sans impact.
drop policy if exists "pro accounts: authenticated can create" on professional_accounts;
drop policy if exists "pro members: creator claims own new account as owner" on professional_members;

notify pgrst, 'reload schema';
