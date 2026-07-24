-- =============================================================================
-- ANSET — Schéma FONDATEUR (projet neuf).
-- Crée les tables de base que les migrations suivantes enrichissent :
--   conseillers, reponses_satisfaction, leads, lead_notes
--   + enum lead_statut + vue v_satisfaction_agence.
-- RLS activée : lecture/écritures applicatives = `authenticated` (policies dans
-- 20260723090600_rls_app.sql) ; les Edge Functions écrivent en service_role
-- (bypass RLS). Idempotent, additif.
-- =============================================================================

-- --- Enum statut de lead -----------------------------------------------------
do $$
begin
  if not exists (select 1 from pg_type where typname = 'lead_statut') then
    create type lead_statut as enum
      ('nouveau','a_contacter','injoignable','rappel','interesse','devis','souscrit','sans_suite','ne_pas_contacter');
  end if;
end $$;

-- --- Conseillers (id = slug texte ; référencé par leads/envois) --------------
create table if not exists public.conseillers (
  id      text primary key,           -- slug « prenom.nom »
  nom     text,
  agence  text,
  created_at timestamptz not null default now()
);

-- --- Réponses au sondage -----------------------------------------------------
-- Colonnes d'attribution (req/conseiller_id/zone) et motif/sinistre/réseaux
-- sociaux ajoutées par les migrations 090500 / 120000 / 130000.
create table if not exists public.reponses_satisfaction (
  id                    uuid primary key default gen_random_uuid(),
  response_id           uuid not null unique,
  date_reponse          timestamptz not null default now(),
  campagne              text,
  agence                text,
  interaction_recente   boolean,
  nps                   smallint,
  nps_categorie         text,
  satisfaction_globale  smallint,
  note_conseiller       smallint,
  note_accueil          smallint,
  commentaire           text,
  a_consenti_recontact  boolean not null default false
);
create index if not exists idx_rs_campagne_base on public.reponses_satisfaction (campagne);

-- --- Leads (prospection ; créés sur consentement + contact) ------------------
create table if not exists public.leads (
  id                   uuid primary key default gen_random_uuid(),
  response_id          uuid unique,
  prenom               text,
  nom                  text,
  telephone            text,
  email                text,
  agence               text,
  conseiller_id        text references public.conseillers(id) on delete set null,
  statut               lead_statut not null default 'nouveau',
  tentatives           integer not null default 0,
  date_consentement    timestamptz,
  campagne             text,
  consentement_source  jsonb,
  created_at           timestamptz not null default now()
);
create index if not exists idx_leads_statut on public.leads (statut);
create index if not exists idx_leads_agence on public.leads (agence);

-- --- Notes de suivi des leads ------------------------------------------------
create table if not exists public.lead_notes (
  id         uuid primary key default gen_random_uuid(),
  lead_id    uuid not null references public.leads(id) on delete cascade,
  note       text not null,
  auteur     text,
  created_at timestamptz not null default now()
);
create index if not exists idx_lead_notes_lead on public.lead_notes (lead_id);

-- --- RLS (policies ajoutées dans 20260723090600_rls_app.sql) -----------------
alter table public.conseillers            enable row level security;
alter table public.reponses_satisfaction  enable row level security;
alter table public.leads                   enable row level security;
alter table public.lead_notes              enable row level security;

-- --- Vue AGENCE (par campagne × agence) — nps_score (alias attendu par l'app) -
-- drop + create : sur un projet déjà configuré, une v_satisfaction_agence
-- préexistante peut avoir un autre ordre de colonnes (create-or-replace échouerait).
drop view if exists public.v_satisfaction_agence;
create view public.v_satisfaction_agence
with (security_invoker = on) as
select campagne, agence,
  count(*)                                             as reponses,
  count(*) filter (where nps >= 9)                     as promoteurs,
  count(*) filter (where nps between 7 and 8)          as passifs,
  count(*) filter (where nps <= 6 and nps is not null) as detracteurs,
  case when count(nps) > 0 then round(100.0*(
        count(*) filter (where nps >= 9) - count(*) filter (where nps <= 6 and nps is not null)
      )/count(nps), 1) end                             as nps_score,
  round(avg(nps)::numeric, 2)                          as nps_moyen,
  round(avg(satisfaction_globale)::numeric, 2)         as csat_global,
  round(avg(note_conseiller)::numeric, 2)              as csat_conseiller
from public.reponses_satisfaction
group by campagne, agence;

grant select on public.v_satisfaction_agence to authenticated;
