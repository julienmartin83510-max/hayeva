-- 0122 — Hygiène sécurité (audit V2 final) :
-- fonctions de trigger non appelables via l'API REST, search_path figé.
revoke execute on function public.bookings_require_account() from public, anon, authenticated;
revoke execute on function public.sync_booking_delete_to_calendar() from public, anon, authenticated;
revoke execute on function public.bookings_calendar_mark_pending() from public, anon, authenticated;
alter function public.credit_notes_no_change() set search_path = public;
alter function public.subcontracts_history() set search_path = public;
