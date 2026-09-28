-- Ajoute les événements du lecteur vidéo "Mon Histoire" à la mesure
-- d'audience existante (analytics_events, voir 0019_visitor_analytics.sql) —
-- jamais un second système d'analytics : mêmes session_id/page, même table,
-- seule la liste autorisée par la contrainte CHECK est élargie (aucune ligne
-- existante n'est modifiée, la contrainte ne fait qu'accepter des valeurs
-- supplémentaires en plus de celles déjà en usage).
alter table analytics_events drop constraint if exists analytics_events_event_type_check;
alter table analytics_events add constraint analytics_events_event_type_check check (event_type in (
  'page_view', 'heartbeat', 'booking_started', 'booking_completed',
  'contact_clicked', 'phone_clicked',
  'story_video_opened', 'story_video_started', 'story_video_25', 'story_video_50',
  'story_video_75', 'story_video_completed', 'story_video_closed',
  'story_video_services_clicked', 'story_video_booking_clicked'
));
