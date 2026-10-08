-- PARRAINAGE — codes générés pour un prénom court (« Zoé » → ZOE23, refusé
-- par la contrainte ^[A-Z0-9]{6,12}$) : le suffixe chiffré est allongé pour
-- toujours atteindre 6 caractères (ZOE123 / ZOE001).
create or replace function public.generate_referral_code_for(p_client uuid)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare v_base text; v text; i int := 0; v_digits int;
begin
  select left(regexp_replace(upper(translate(coalesce(first_name, ''),
           'àâäáãåçéèêëíìîïñóòôöõúùûüýÿÀÂÄÁÃÅÇÉÈÊËÍÌÎÏÑÓÒÔÖÕÚÙÛÜÝ',
           'aaaaaaceeeeiiiinooooouuuuyyAAAAAACEEEEIIIINOOOOOUUUUY')), '[^A-Z]', '', 'g'), 8)
    into v_base from clients where id = p_client;
  if coalesce(length(v_base), 0) >= 3 then
    v_digits := greatest(2, 6 - length(v_base));
    loop
      i := i + 1;
      v := v_base || (power(10, v_digits - 1) + floor(random() * 9 * power(10, v_digits - 1)))::bigint::text;
      exit when not referral_code_taken(v, null);
      if i > 20 then exit; end if;
    end loop;
    if i <= 20 then return v; end if;
  end if;
  return generate_referral_code();
end;
$$;

create or replace function public.admin_suggest_referral_code(p_first_name text)
returns text
language plpgsql
stable
security definer
set search_path = public
as $$
declare v_base text; v text; i int;
begin
  if not is_admin() then raise exception 'Accès réservé à l''administration.'; end if;
  v_base := left(regexp_replace(upper(translate(coalesce(p_first_name, ''),
           'àâäáãåçéèêëíìîïñóòôöõúùûüýÿÀÂÄÁÃÅÇÉÈÊËÍÌÎÏÑÓÒÔÖÕÚÙÛÜÝ',
           'aaaaaaceeeeiiiinooooouuuuyyAAAAAACEEEEIIIINOOOOOUUUUY')), '[^A-Z]', '', 'g'), 10);
  if length(v_base) < 2 then v_base := 'HAYEVA'; end if;
  for i in 1..99 loop
    v := v_base || lpad(i::text, greatest(2, 6 - length(v_base)), '0');
    if length(v) between 6 and 12 and not referral_code_taken(v, null) then return v; end if;
  end loop;
  return generate_referral_code();
end;
$$;
