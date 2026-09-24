-- ============================================================
-- Motif de refus admin (facultatif) — colonne admin-only, jamais transmise
-- au client (contrairement à bookings.notes, déjà affiché dans l'Espace
-- Client). Ajout additif, nullable : ne casse rien si non exécutée, le
-- refus lui-même (status='CANCELLED') fonctionne déjà sans cette colonne.
-- ============================================================
alter table bookings add column if not exists admin_cancel_reason text;
comment on column bookings.admin_cancel_reason is 'Motif interne du refus d''une demande par l''admin (facultatif, jamais affiché au client). Renseigné uniquement quand cancelled_by = ''admin''.';
