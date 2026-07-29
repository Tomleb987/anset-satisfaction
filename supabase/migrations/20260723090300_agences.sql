-- =====================================================================
--  Table de correspondance des agences (code requête -> nom/zone)
--  Sert à traduire le code numérique de la requête mensuelle.
-- =====================================================================

create table if not exists public.agences (
  code   text primary key,
  nom    text not null,
  zone   text,
  active boolean not null default true
);

insert into public.agences (code, nom, zone, active) values
  ('1000','Papeete','Zone Est',true),
  ('1010','Taravao','Zone Ouest',true),
  ('1011','Polynésie Assurances','Polynésie Assurances',true),
  ('1020','Punaauia','Zone Ouest',true),
  ('1030','Faa''a','Zone Ouest',true),
  ('1040','Fariipiti','Zone Est',true),
  ('1050','Paea','Zone Ouest',false),        -- agence fermée
  ('1060','Papara','Zone Ouest',true),
  ('1070','Mahina','Zone Est',true),
  ('1080','Moorea','Zone Est',true),
  ('1090','Agence en ligne','AEL',true),     -- ~570 clients
  ('1095','Site WEB','AEL',true),            -- Web
  ('1099','Commerciaux','Commerciaux',true)
on conflict (code) do update
  set nom = excluded.nom, zone = excluded.zone, active = excluded.active;

-- Tout code absent de cette table est traité comme « Autre » / zone « (non précisée) »
-- côté import (ne pas insérer de ligne « Autre » ici : c'est un fallback applicatif).

alter table public.agences enable row level security;
drop policy if exists auth_read_agences on public.agences;
create policy auth_read_agences on public.agences
  for select to authenticated using (true);
