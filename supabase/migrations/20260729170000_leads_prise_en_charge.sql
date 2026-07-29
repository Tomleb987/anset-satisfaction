-- =============================================================================
--  ANSET — Prospection : suivi du traitement par conseiller.
--
--  Un lead avait déjà `conseiller_id`, mais c'est le conseiller D'ORIGINE : celui
--  qui a servi le client au moment du sondage (pré-attribution faite par
--  `submit-sondage` à partir du lien personnalisé). Il répond à « d'où vient ce
--  lead ? », pas à « qui le traite ? » — et l'écraser ferait perdre la traçabilité
--  de la source. D'où une colonne dédiée.
--
--   * `traite_par`           → conseiller qui prend le lead en charge (menu déroulant
--                              dans l'onglet Prospection). NULL = non attribué.
--   * `date_prise_en_charge` → horodatage de l'attribution, posé à la sélection.
--
--  `on delete set null` : supprimer un conseiller ne doit pas supprimer le lead,
--  il repasse simplement « non attribué ». Additif, idempotent.
-- =============================================================================

alter table public.leads
  add column if not exists traite_par text
    references public.conseillers(id) on delete set null;

alter table public.leads
  add column if not exists date_prise_en_charge timestamptz;

comment on column public.leads.conseiller_id is
  'Conseiller d''origine : celui qui a servi le client lors du contact sondé (pré-attribution). Ne pas utiliser pour le suivi de prospection.';
comment on column public.leads.traite_par is
  'Conseiller qui prend le lead en charge en prospection. NULL = non attribué.';

-- Filtre « pris en charge par » et comptage des non-attribués.
create index if not exists idx_leads_traite_par on public.leads (traite_par);

-- Les policies `authenticated` de 20260723090600_rls_app.sql portent sur la table
-- entière (select + update sans restriction de colonne) : rien à ajouter.
