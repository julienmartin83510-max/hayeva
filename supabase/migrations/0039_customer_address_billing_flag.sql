-- Distingue l'adresse de facturation des adresses d'intervention dans
-- l'Espace Client, sans toucher au modèle existant : ajout additif d'une
-- seule colonne booléenne, sur le même principe que is_default (pas de
-- contrainte d'unicité SQL, l'exclusivité est maintenue côté application
-- par ecMakeBillingAddress, comme ecMakeDefaultAddress pour is_default).
-- Aucune ligne existante n'est modifiée : la valeur par défaut (false)
-- signifie "facturation identique à l'adresse principale", qui reste le
-- comportement actuel pour tous les comptes déjà créés.
alter table customer_addresses add column if not exists is_billing boolean not null default false;
