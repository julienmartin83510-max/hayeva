-- ============================================================
-- Corrige verify_distance_quote() : hmac() est introuvable même avec les
-- casts ::bytea corrects — "function hmac(bytea, bytea, unknown) does not
-- exist" constaté en test réel. Cause : sur Supabase, pgcrypto s'installe
-- dans le schéma "extensions", pas "public" ; set search_path = public
-- (seul) rend donc hmac() invisible malgré create extension pgcrypto déjà
-- exécuté avec succès. Ajoute "extensions" au search_path.
create or replace function verify_distance_quote(p_quote text)
returns table(valid boolean, distance_km numeric, lat double precision, lng double precision)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_secret text;
  v_dot_pos int;
  v_payload_b64 text;
  v_signature text;
  v_expected_sig text;
  v_payload json;
  v_issued_at bigint;
begin
  if p_quote is null or p_quote = '' then
    return query select false, null::numeric, null::double precision, null::double precision;
    return;
  end if;

  v_dot_pos := position('.' in p_quote);
  if v_dot_pos = 0 then
    return query select false, null::numeric, null::double precision, null::double precision;
    return;
  end if;
  v_payload_b64 := substring(p_quote from 1 for v_dot_pos - 1);
  v_signature := substring(p_quote from v_dot_pos + 1);

  select decrypted_secret into v_secret from vault.decrypted_secrets where name = 'quote_signing_secret';
  if v_secret is null then
    return query select false, null::numeric, null::double precision, null::double precision;
    return;
  end if;

  v_expected_sig := encode(hmac(v_payload_b64::bytea, v_secret::bytea, 'sha256'), 'hex');
  if v_expected_sig <> v_signature then
    return query select false, null::numeric, null::double precision, null::double precision;
    return;
  end if;

  begin
    v_payload := convert_from(decode(v_payload_b64, 'base64'), 'UTF8')::json;
  exception when others then
    return query select false, null::numeric, null::double precision, null::double precision;
    return;
  end;

  v_issued_at := (v_payload->>'issued_at')::bigint;
  if v_issued_at is null or (extract(epoch from now()) * 1000 - v_issued_at) > (30 * 60 * 1000) then
    return query select false, null::numeric, null::double precision, null::double precision;
    return;
  end if;

  return query select
    true,
    (v_payload->>'distance_km')::numeric,
    (v_payload->>'lat')::double precision,
    (v_payload->>'lng')::double precision;
end;
$$;
revoke all on function verify_distance_quote(text) from public;
