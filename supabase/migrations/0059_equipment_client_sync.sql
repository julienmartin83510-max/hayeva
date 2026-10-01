-- ============================================================
-- Bug réel trouvé en audit sécurité/intégrité (Priorité 0, cahier des
-- charges HAYEVA du 05/10/2026) : un équipement créé depuis l'Espace
-- Client (customer_user_id posé, client_id absent) n'apparaissait jamais
-- dans la fiche 360° (qui filtre par client_id) — et inversement, un
-- équipement créé depuis la fiche 360° (client_id posé) n'apparaissait
-- plus dans "Mes équipements" côté client ni dans le sélecteur
-- d'équipement de la fiche d'intervention (qui filtraient sur
-- customer_user_id seul). Corrigé côté frontend pour le sens fiche→client ;
-- ce trigger corrige le sens client→fiche de façon durable, pour toute
-- insertion présente ou future, sans dépendre de chaque point d'entrée
-- du code qui écrit dans customer_equipment.
-- ============================================================

create or replace function equipment_attach_client()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.client_id is null and new.customer_user_id is not null then
    new.client_id := find_or_create_client(new.customer_user_id, null, null, null, null, null);
  end if;
  return new;
end;
$$;

drop trigger if exists trg_equipment_attach_client on customer_equipment;
create trigger trg_equipment_attach_client
  before insert on customer_equipment
  for each row execute function equipment_attach_client();

comment on function equipment_attach_client is 'Garantit que tout équipement rattaché à un customer_user_id l''est aussi à sa fiche client (clients.id) — sans quoi il resterait invisible dans le dossier client 360°.';

-- Rétro-remplissage des équipements déjà existants (créés avant ce
-- trigger) qui portent un customer_user_id mais pas encore de client_id —
-- aucune donnée modifiée hormis cette colonne additive.
update customer_equipment e set client_id = c.id
from clients c
where e.client_id is null and e.customer_user_id is not null and c.user_id = e.customer_user_id;
