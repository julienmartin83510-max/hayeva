-- Mentions légales publiques alimentées par Admin › Paramètres ›
-- Informations entreprise (company_settings, ligne unique id=1). Aucune
-- valeur par défaut : un champ vide reste vide (jamais inventé).
alter table public.company_settings
  add column if not exists legal_form text,
  add column if not exists rcs_number text,
  add column if not exists publication_director text;

-- Lecture publique limitée aux seules informations légalement destinées à
-- être affichées dans les mentions légales (identité, adresse, immatriculation,
-- assurance, médiateur). company_settings reste réservée aux admins.
create or replace function public.get_public_legal_info()
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select coalesce((
    select jsonb_strip_nulls(jsonb_build_object(
      'companyRegistered', (nullif(trim(c.siret), '') is not null),
      'entrepreneurName', nullif(trim(coalesce(nullif(trim(c.legal_name), ''), c.owner_name)), ''),
      'legalForm', nullif(trim(c.legal_form), ''),
      'professionalAddress', nullif(trim(concat_ws(', ', nullif(trim(c.address_line1), ''), nullif(trim(c.address_line2), ''), nullif(trim(concat_ws(' ', nullif(trim(c.postal_code), ''), nullif(trim(c.city), ''))), ''))), ''),
      'siren', nullif(trim(c.siren), ''),
      'siret', nullif(trim(c.siret), ''),
      'rcs', nullif(trim(c.rcs_number), ''),
      'vatNumber', nullif(trim(c.vat_number), ''),
      'vatRegime', nullif(trim(c.vat_regime), ''),
      'publicationDirector', nullif(trim(coalesce(nullif(trim(c.publication_director), ''), c.owner_name)), ''),
      'insurer', nullif(trim(c.insurance_company), ''),
      'insurancePolicyNumber', nullif(trim(c.insurance_contract_number), ''),
      'insuranceCoverage', nullif(trim(c.insurance_coverage), ''),
      'mediatorName', nullif(trim(c.mediator_name), ''),
      'mediatorContact', nullif(trim(c.mediator_contact), '')
    ))
    from public.company_settings c where c.id = 1
  ), '{}'::jsonb);
$$;

revoke all on function public.get_public_legal_info() from public;
grant execute on function public.get_public_legal_info() to anon, authenticated, service_role;
