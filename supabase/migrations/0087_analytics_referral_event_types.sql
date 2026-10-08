-- Analytics : la contrainte CHECK de analytics_events n'acceptait pas les
-- événements du parrainage (déjà autorisés par la policy d'insertion depuis
-- 0082) → insertion refusée (23514). Élargissement uniquement : toutes les
-- valeurs existantes restent acceptées, aucune ligne modifiée. Aucune donnée
-- personnelle : type d'événement + session anonyme + page.
alter table public.analytics_events drop constraint if exists analytics_events_event_type_check;
alter table public.analytics_events add constraint analytics_events_event_type_check check (event_type in (
  'page_view', 'heartbeat', 'booking_started', 'booking_completed', 'contact_clicked', 'phone_clicked',
  'story_video_opened', 'story_video_started', 'story_video_25', 'story_video_50', 'story_video_75',
  'story_video_completed', 'story_video_closed', 'story_video_services_clicked', 'story_video_booking_clicked',
  'referral_page_view', 'referral_signup', 'referral_link_shared', 'referral_code_applied', 'referral_booking_completed',
  'referral_reward_pending', 'referral_reward_validated', 'referral_payout_requested'));
