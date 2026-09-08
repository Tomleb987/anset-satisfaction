-- =============================================================================
--  ANSET — L'attribution d'une réponse passe du GESTIONNAIRE au RÉDACTEUR.
--
--  CONSTAT (08/09/2026, requête mensuelle réelle, 5 114 lignes) :
--   · la requête porte DEUX colonnes de personnel, « Redacteur » et
--     « Gestionnaire ». L'import ne lisait que la seconde ; la première était
--     silencieusement jetée par `mapReqHeaders` ;
--   · elles divergent sur 3 024 lignes (59,1 %). Le rédacteur est celui qui a
--     établi le contrat et parlé au client — c'est lui que le client note quand
--     le formulaire demande « Votre conseiller ? ». Le gestionnaire suit le
--     portefeuille et n'a pas forcément eu le client au téléphone ;
--   · 34 rédacteurs n'apparaissent JAMAIS comme gestionnaire : ni compte, ni
--     ligne dans les indicateurs. Leurs notes créditaient quelqu'un d'autre ;
--   · 105 lignes sans gestionnaire mais avec un rédacteur n'étaient attribuées
--     à personne.
--
--  CE QUE FAIT CETTE MIGRATION :
--   1. `envois_sondage.gestionnaire_id` — le gestionnaire cesse d'être perdu.
--      Rétro-rempli depuis `conseiller_id`, qui JUSQU'ICI était le gestionnaire.
--   2. `import_redacteur` — table de correspondance `req → rédacteur`, à charger
--      depuis les requêtes .xlsx des mois déjà diffusés (voir
--      `scripts/redacteur_mapping.py`). L'information n'existe nulle part en
--      base : elle ne peut venir que des fichiers source.
--   3. `appliquer_redacteur()` — rebascule l'historique à partir de cette table.
--
--  PÉRIMÈTRE SINISTRE INTACT : l'export « sinistres clos » n'a pas de colonne
--  rédacteur, et son gestionnaire a réellement traité le dossier. Toute ligne
--  dont un envoi porte `motif = 'sinistre'` est écartée de la rebascule.
--
--  Additif et idempotent : `appliquer_redacteur()` est rejouable, elle ne
--  réécrit que ce qui diffère.
-- =============================================================================

-- --- 1. Conserver le gestionnaire ------------------------------------------
alter table public.envois_sondage
  add column if not exists gestionnaire_id text;

comment on column public.envois_sondage.conseiller_id is
  'Personne notée par le client : colonne « Redacteur » de la requête, à défaut « Gestionnaire » (et gestionnaire seul pour les campagnes sinistre).';
comment on column public.envois_sondage.gestionnaire_id is
  'Colonne « Gestionnaire » de la requête, conservée telle quelle. Suivi de portefeuille — ce n''est PAS la personne notée.';

-- Rétro-remplissage : avant le 08/09/2026, `conseiller_id` ÉTAIT le gestionnaire.
-- Deux gardes, et `is null` seule ne suffit pas : les imports POSTÉRIEURS écrivent
-- déjà les deux colonnes, mais laissent `gestionnaire_id` null quand la cellule
-- « Gestionnaire » est vide (52 lignes sur 5 114). Un rejeu de cette migration —
-- `supabase db reset` en local, ou une reprise à blanc — y recopierait alors le
-- RÉDACTEUR sous l'étiquette gestionnaire, soit exactement la confusion que la
-- migration défait. La borne sur `created_at` la rend franchement une-seule-fois.
update public.envois_sondage
   set gestionnaire_id = conseiller_id
 where gestionnaire_id is null
   and conseiller_id is not null
   and created_at < '2026-09-08'::timestamptz;

-- --- 2. Correspondance req → rédacteur --------------------------------------
-- Chargée hors migration (éditeur SQL), parce que la donnée vit dans les .xlsx
-- mensuels et non en base. Conservée après coup : elle est la trace de ce qui a
-- été rebasculé, et le seul moyen de rejouer si un mois arrive en retard.
create table if not exists public.import_redacteur (
  req        text primary key,
  redacteur  text not null,
  charge_le  timestamptz not null default now()
);

comment on table public.import_redacteur is
  'Correspondance `req` → rédacteur, extraite des requêtes .xlsx déjà diffusées (scripts/redacteur_mapping.py). Alimente appliquer_redacteur().';

-- Aucune policy : la table n'est lue que par l'éditeur SQL et la fonction
-- ci-dessous (security definer). Les rôles applicatifs n'ont rien à y faire.
alter table public.import_redacteur enable row level security;

-- --- 3. Rebascule de l'historique -------------------------------------------
create or replace function public.appliquer_redacteur()
returns table (
  conseillers_crees   integer,
  envois_rebascules   integer,
  reponses_rebasculee integer,
  leads_rebascules    integer,
  reqs_ignores_sin    integer
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_cons int; v_env int; v_rep int; v_lead int; v_sin int;
begin
  -- Périmètre : tout `req` de la correspondance, SAUF ceux qui portent un envoi
  -- sinistre. Les deux imports peuvent produire la même clé (`Dossier` d'un côté,
  -- `num_sinistre` de l'autre) ; en cas de doute on ne touche pas au sinistre.
  create temp table _cible on commit drop as
  select m.req, nullif(btrim(m.redacteur), '') as redacteur
    from public.import_redacteur m
   where nullif(btrim(m.redacteur), '') is not null
     and not exists (
           select 1 from public.envois_sondage e
            where e.req = m.req and e.motif = 'sinistre');

  select count(*) into v_sin
    from public.import_redacteur m
   where exists (select 1 from public.envois_sondage e
                  where e.req = m.req and e.motif = 'sinistre');

  -- 3a. Les rédacteurs absents de `conseillers` : la FK d'`envois_sondage` les
  -- exige, et le menu de création de comptes lit cette même table.
  with nouveaux as (
    insert into public.conseillers (id, nom)
    select distinct c.redacteur, initcap(replace(c.redacteur, '.', ' '))
      from _cible c
    on conflict (id) do nothing
    returning 1
  )
  select count(*) into v_cons from nouveaux;

  -- 3b. Invitations.
  with maj as (
    update public.envois_sondage e
       set conseiller_id = c.redacteur
      from _cible c
     where e.req = c.req
       and e.conseiller_id is distinct from c.redacteur
    returning 1
  )
  select count(*) into v_env from maj;

  -- 3c. Réponses. `reponses_satisfaction.conseiller_id` n'a volontairement pas de
  -- FK : on écrit le slug tel quel. Le filtre sinistre est porté par `_cible`, pas
  -- par `r.motif` — un répondant de campagne quittance peut avoir DÉCLARÉ
  -- « sinistre » sans que sa note appartienne au pôle sinistres.
  with maj as (
    update public.reponses_satisfaction r
       set conseiller_id = c.redacteur
      from _cible c
     where r.req = c.req
       and r.conseiller_id is distinct from c.redacteur
    returning 1
  )
  select count(*) into v_rep from maj;

  -- 3d. Leads : `conseiller_id` y est le conseiller D'ORIGINE, celui qui a servi
  -- le client lors du contact sondé — donc le rédacteur lui aussi. `traite_par`
  -- (prise en charge en prospection) n'est PAS touché.
  with maj as (
    update public.leads l
       set conseiller_id = c.redacteur
      from public.reponses_satisfaction r
      join _cible c on c.req = r.req
     where l.response_id = r.response_id
       and l.conseiller_id is distinct from c.redacteur
    returning 1
  )
  select count(*) into v_lead from maj;

  drop table _cible;

  conseillers_crees   := v_cons;
  envois_rebascules   := v_env;
  reponses_rebasculee := v_rep;
  leads_rebascules    := v_lead;
  reqs_ignores_sin    := v_sin;
  return next;
end $$;

revoke all on function public.appliquer_redacteur() from public;

comment on function public.appliquer_redacteur() is
  'Rebascule envois / réponses / leads du gestionnaire vers le rédacteur, à partir de public.import_redacteur. Rejouable. N''exécute rien tant que la table est vide.';
