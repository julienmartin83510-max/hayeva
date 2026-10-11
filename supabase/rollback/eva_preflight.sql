-- CONTRÔLE AVANT MISE EN PRODUCTION d'EVA (0135 → 0137). LECTURE SEULE.
-- Vérifie que la production n'a pas changé depuis l'audit du 11/10/2026 :
-- si une ligne « BLOQUANT » apparaît, NE PAS appliquer les migrations et refaire l'audit.
with expected(sig, h) as (values
('_invoice_recompute_draft(uuid)', '547e1c33312bc3fbb822201eaa001278'),
('admin_adjust_wallet(uuid,integer,text)', '6d0cc00584eed35525559dcf93b2aefd'),
('admin_booking_stats(date,date)', '83f47d5b4186a5d2ad6d0a4854615933'),
('admin_create_invoice(text,uuid)', '5b824cc01264f29dd5ff347ac528a6a8'),
('admin_issue_invoice(uuid,date)', 'f5afcd22552ef2b4310a61ab8c8e9da2'),
('admin_list_referrers(text,text)', 'ee2fac27fb7b73704ccb33d8ad959b7c'),
('admin_record_invoice_payment(uuid,integer,text,date,text)', '78d58f2264f33475423b45975c3388d9'),
('admin_reschedule_booking(uuid,date,time without time zone)', '00c89b016a837b9c15d748ca3b87a64c'),
('admin_set_referrer_code(uuid,text)', '81df397aafcee19fa9741cd20136954c'),
('admin_set_referrer_status(uuid,text)', '7245330674d8ed3d5c0a6c25da4de66f'),
('booking_free_slots(uuid,date)', 'f7f0a0561f767c3192eb55f12d2eeba3'),
('check_calendar_block_conflict(date,time without time zone,integer)', '3a8dfdb4d87387da68aaf97895223b07'),
('company_billing_ready()', '655e08599a7fc76677104c5c7bf2ea84'),
('compute_travel_fee_cents(numeric,boolean)', '8ecb3cea71f0ff1f84103b1839bfe3ca'),
('equipment_next_maintenance_due(customer_equipment)', '38037ad4eb2ebae5952716fb57ca1d7f'),
('find_or_create_client(uuid,text,text,text,text,text)', '6d1b4c044f96ce2eebd9a5c19225b91f'),
('get_public_booking_settings()', 'dcee484ea681c129ca7eb5720e8bcb18'),
('is_admin()', '8a32945cf565e0d54a4a2429946abdfb'),
('is_slot_within_business_hours(date,time without time zone,integer)', '32986e45f15eeab15eac55f400363ff7'),
('next_document_number(text)', '2886c38b046e2336b023460c86295e9a'),
('quotes_assign_number()', 'bd7d6ed8412d24dd84816012630fa356'))
select 'BLOQUANT : fonction modifiée depuis l''audit : ' || e.sig
  from expected e left join pg_proc p on p.oid::regprocedure::text = e.sig and p.pronamespace = 'public'::regnamespace
 where p.oid is null or md5(pg_get_functiondef(p.oid)) <> e.h
union all select 'BLOQUANT : objet EVA déjà présent : ' || relname from pg_class where relnamespace = 'public'::regnamespace and relname like 'eva\_%'
union all select 'BLOQUANT : extension pgcrypto absente' where not exists (select 1 from pg_extension where extname = 'pgcrypto')
union all select 'BLOQUANT : colonne déjà présente : ' || table_name || '.' || column_name from information_schema.columns
 where table_schema = 'public' and ((table_name = 'booking_settings' and column_name in ('work_hours', 'travel_margin_minutes')) or (table_name = 'company_settings' and column_name like 'vat_regime_confirmed%'))
union all select 'OK : contrôle terminé (' || (select count(*) from expected) || ' fonctions vérifiées)';
