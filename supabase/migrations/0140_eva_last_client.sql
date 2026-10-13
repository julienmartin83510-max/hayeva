-- 0140 — EVA : « retrouve mon dernier client ».
-- _eva_find_client accepte la requête réservée « @dernier » : la dernière
-- fiche client créée (hors fiches fusionnées). Toute autre requête est
-- traitée exactement comme avant (0135). Lecture seule, aucun nouveau droit.
create or replace function public._eva_find_client(p_query text)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_q text := trim(coalesce(p_query, '')); v_words text[]; v_digits text;
begin
  if v_q = '@dernier' then
    return jsonb_build_object('query', 'dernier client', 'last', true, 'clients', coalesce((
      select jsonb_agg(jsonb_build_object('client_id', c.id, 'name', trim(coalesce(c.first_name, '') || ' ' || coalesce(c.last_name, '')),
               'city', c.city, 'phone', c.phone, 'email', c.email, 'type', c.client_type, 'created_at', c.created_at))
        from (select * from clients c where c.merged_into is null order by c.created_at desc, c.id desc limit 1) c), '[]'::jsonb));
  end if;
  if char_length(v_q) < 2 then return jsonb_build_object('query', v_q, 'clients', '[]'::jsonb); end if;
  v_words := regexp_split_to_array(_eva_norm(regexp_replace(v_q, '\m(monsieur|madame|mme|mlle|m\.|mr)\M', '', 'gi')), '\s+');
  v_words := array(select w from unnest(v_words) w where char_length(w) >= 2);
  v_digits := regexp_replace(v_q, '\D', '', 'g');
  return jsonb_build_object('query', v_q, 'clients', coalesce((
    select jsonb_agg(jsonb_build_object('client_id', c.id, 'name', trim(coalesce(c.first_name, '') || ' ' || coalesce(c.last_name, '')),
             'city', c.city, 'phone', c.phone, 'email', c.email, 'type', c.client_type) order by c.last_name, c.first_name)
      from (select * from clients c
             where c.merged_into is null
               and ((cardinality(v_words) > 0 and not exists (select 1 from unnest(v_words) w
                      where position(w in _eva_norm(coalesce(c.first_name, '') || ' ' || coalesce(c.last_name, '') || ' ' || coalesce(c.email, '') || ' ' || coalesce(c.city, ''))) = 0))
                 or (char_length(v_digits) >= 6 and regexp_replace(coalesce(c.phone, ''), '\D', '', 'g') like '%' || v_digits || '%'))
             limit 8) c), '[]'::jsonb));
end $$;
revoke all on function public._eva_find_client(text) from public, anon, authenticated;
