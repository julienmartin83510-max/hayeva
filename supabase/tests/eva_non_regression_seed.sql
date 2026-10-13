insert into vault.secrets (name, secret) values ('webhook_secret', 'local-test-secret') on conflict (name) do nothing;
update booking_settings set opening_date = date '2027-01-02' where id = 1;
do $$ declare u record; begin
  for u in select * from (values
    ('00000000-0000-0000-0000-0000000000a1'::uuid, 'admin@test.local', 'admin', 'Ada', 'Admin', '0600000001', '1 rue Admin'),
    ('00000000-0000-0000-0000-0000000000c1'::uuid, 'martin@test.local', 'customer', 'Paul', 'Martin', '0699887766', '2 place Centrale'),
    ('00000000-0000-0000-0000-0000000000c2'::uuid, 'dupont@test.local', 'customer', 'Jean', 'Dupont', '0611223344', '5 rue des Pins')) v(id, email, role, fn, ln, ph, addr) loop
    insert into auth.users (id, email) values (u.id, u.email) on conflict do nothing;
    insert into profiles (user_id, email, global_role) values (u.id, u.email, u.role) on conflict (user_id) do update set global_role = excluded.global_role;
    insert into customer_profiles (user_id, first_name, last_name, phone) values (u.id, u.fn, u.ln, u.ph) on conflict (user_id) do nothing;
    perform find_or_create_client(u.id, u.email, u.ph, u.fn, u.ln, u.addr);
  end loop;
end $$;
update clients set city = 'Le Muy', postal_code = '83490' where email = 'martin@test.local';
