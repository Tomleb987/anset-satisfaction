-- =====================================================================
--  Table envois_sondage — SOURCE des invitations mensuelles.
--  Une ligne par client à interroger (issue de la requête .xlsx du mois).
--  Alimentée par l'import "requête" (manager connecté), consommée par
--  l'Edge Function `envoi-sondage` (Brevo).
--  Idempotent : rejouable via `supabase db push`.
-- =====================================================================

-- Enum statut d'envoi (garde : create type sans "if not exists").
do $$
begin
  if not exists (select 1 from pg_type where typname = 'envoi_statut') then
    create type envoi_statut as enum ('a_envoyer', 'envoye', 'exclu');
  end if;
end $$;

create table if not exists public.envois_sondage (
  id               uuid primary key default gen_random_uuid(),
  req              text,                       -- clé requête (Quittance ou Dossier)
  campagne         text not null,              -- YYYY-MM
  email            text,
  nom              text,
  prenom           text,
  telephone        text,
  agence           text,                       -- nom résolu (via table agences)
  zone             text,
  conseiller_id    text references public.conseillers(id) on delete set null, -- mappé depuis Gestionnaire (id = slug texte)
  produit          text,
  police           text,
  dossier          text,
  statut_envoi     envoi_statut not null default 'a_envoyer',
  motif_exclusion  text,
  date_envoi       timestamptz,
  created_at       timestamptz not null default now(),
  -- Idempotence import : une seule invitation par client et par mois.
  -- Contrainte (non partielle) pour que l'upsert PostgREST onConflict fonctionne ;
  -- les emails NULL (lignes exclues sans email) restent distincts en SQL.
  constraint uq_envois_campagne_email unique (campagne, email)
);

create index if not exists idx_envois_statut   on public.envois_sondage (statut_envoi);
create index if not exists idx_envois_campagne on public.envois_sondage (campagne);
create index if not exists idx_envois_req       on public.envois_sondage (req);

-- --- RLS : géré par des managers connectés (import) ; la fonction Brevo
--          passe par la service_role (bypass RLS).
alter table public.envois_sondage enable row level security;

drop policy if exists auth_select_envois on public.envois_sondage;
create policy auth_select_envois on public.envois_sondage
  for select to authenticated using (true);

drop policy if exists auth_insert_envois on public.envois_sondage;
create policy auth_insert_envois on public.envois_sondage
  for insert to authenticated with check (true);

drop policy if exists auth_update_envois on public.envois_sondage;
create policy auth_update_envois on public.envois_sondage
  for update to authenticated using (true) with check (true);
