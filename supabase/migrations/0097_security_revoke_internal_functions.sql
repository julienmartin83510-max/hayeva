-- SÉCURITÉ — fonctions internes exposées à tort via l'API publique.
-- Les fonctions créées sans REVOKE héritent du droit EXECUTE accordé à
-- PUBLIC : elles étaient appelables par n'importe quel visiteur
-- (/rest/v1/rpc/...). Deux d'entre elles renvoyaient des secrets du coffre
-- Supabase. Elles ne sont utilisées que par des Edge Functions (service_role),
-- des déclencheurs ou des tâches planifiées : retrait des droits publics.
revoke all on function public.get_apple_caldav_app_password() from public, anon, authenticated;
revoke all on function public.get_quote_signing_secret() from public, anon, authenticated;
grant execute on function public.get_apple_caldav_app_password() to service_role;
grant execute on function public.get_quote_signing_secret() to service_role;

-- Fonctions internes (déclencheurs / tâches / fonctions serveur) : jamais
-- appelées depuis le navigateur.
revoke all on function public.stock_deduct_for_intervention(uuid) from public, anon, authenticated;
revoke all on function public.admin_notify(text, text, text, uuid, text, boolean) from public, anon, authenticated;
revoke all on function public.admin_intervention_reminders() from public, anon, authenticated;
revoke all on function public.generate_reminder_jobs() from public, anon, authenticated;
revoke all on function public.find_or_create_client(uuid, text, text, text, text, text) from public, anon, authenticated;
revoke all on function public.booking_contact_name(public.bookings) from public, anon, authenticated;
revoke all on function public.check_calendar_block_conflict(date, time without time zone, integer) from public, anon, authenticated;
revoke all on function public.compute_travel_fee_cents(numeric, boolean) from public, anon, authenticated;
revoke all on function public.verify_distance_quote(text) from public, anon, authenticated;
grant execute on function public.stock_deduct_for_intervention(uuid), public.admin_notify(text, text, text, uuid, text, boolean),
  public.admin_intervention_reminders(), public.generate_reminder_jobs(), public.find_or_create_client(uuid, text, text, text, text, text),
  public.booking_contact_name(public.bookings), public.check_calendar_block_conflict(date, time without time zone, integer),
  public.compute_travel_fee_cents(numeric, boolean), public.verify_distance_quote(text) to service_role;
-- company_billing_ready : lu par l'administration (utilisateur connecté), pas par les visiteurs.
revoke all on function public.company_billing_ready() from public, anon;
grant execute on function public.company_billing_ready() to authenticated, service_role;

-- search_path figé (recommandation Supabase).
alter function public.enforce_single_default_prep_instruction() set search_path = public;
alter function public.launch_campaign_participant_key(public.bookings) set search_path = public;
alter function public.set_updated_at() set search_path = public;
alter function public.quote_option_recompute_total() set search_path = public;
alter function public.supplier_product_recompute_sale_price() set search_path = public;
alter function public.referral_stage(text, text, text, text) set search_path = public;
