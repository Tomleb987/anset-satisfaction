-- =============================================================================
--  ANSET — Le numéro de contrat du client dans les verbatims.
--
--  BESOIN : lire un commentaire sans savoir de quel contrat il parle oblige à
--  rechercher le client à la main dans le fichier source. Le numéro est déjà en
--  base — `envois_sondage.police`, colonne « Police » des deux fichiers
--  d'import (requête générale ET sinistres clos) — mais il ne remontait pas
--  jusqu'à la vue lue par le dashboard.
--
--  CHEMIN : `reponses_satisfaction` ne porte PAS le contrat (le formulaire ne le
--  demande pas, et ne doit pas le demander — minimisation RGPD). Le lien se fait
--  par `req`, la clé que l'invitation transporte dans l'URL. On réutilise
--  `v_envoi_reference` (ligne d'envoi réellement partie, la plus récente) plutôt
--  qu'un join direct sur `envois_sondage` : un même `req` existe dans plusieurs
--  campagnes, et c'est exactement le piège que cette vue existe pour éviter.
--
--  Une réponse sans `req` (formulaire ouvert en direct, hors lien personnalisé)
--  n'a pas de contrat : la colonne vaut null, et l'app n'affiche alors rien.
--
--  RLS : `security_invoker = on` conservé des deux côtés. Un compte conseiller ne
--  lit d'`envois_sondage` que ses propres lignes (20260730100000) ; le contrat
--  suit donc le même périmètre que le verbatim lui-même, sans élargir personne.
--  Additif, idempotent.
-- =============================================================================

-- --- v_envoi_reference : porter la police ------------------------------------
-- `create or replace` : colonne ajoutée EN FIN de liste, l'ordre existant est
-- intact — les vues qui lisent déjà cette vue par nom ne bougent pas.
create or replace view public.v_envoi_reference
with (security_invoker = on) as
select distinct on (req)
       req, campagne, agence, zone, conseiller_id, motif, date_envoi, police
  from public.envois_sondage
 where req is not null and date_envoi is not null
 order by req, date_envoi desc;

-- --- v_verbatims : exposer le contrat ----------------------------------------
-- drop + create (et non « create or replace ») : la vue déployée peut avoir été
-- posée par 20260724120000, dont l'ordre de colonnes n'est pas garanti identique
-- ici. Un create-or-replace échouerait sur le moindre écart ; le drop est sûr,
-- aucune autre vue ne dépend de v_verbatims.
drop view if exists public.v_verbatims;
create view public.v_verbatims
with (security_invoker = on) as
select rs.response_id, rs.date_reponse, rs.campagne, rs.agence, rs.zone, rs.conseiller_id, rs.motif,
  rs.nps, rs.nps_categorie, rs.satisfaction_globale, rs.note_conseiller,
  rs.sat_sinistre, rs.delai_indemnisation, rs.commentaire,
  (coalesce(rs.nps, 10) <= 6 or coalesce(rs.satisfaction_globale, 5) <= 3) as detracteur,
  -- Nommé `contrat` et non `police` : c'est le mot du métier côté lecture d'un
  -- verbatim. La source reste `envois_sondage.police`.
  ref.police as contrat
from public.reponses_satisfaction rs
  left join public.v_envoi_reference ref on ref.req = rs.req
where rs.commentaire is not null and length(btrim(rs.commentaire)) > 0;

comment on view public.v_verbatims is
  'Commentaires clients + contexte de la réponse. `contrat` = envois_sondage.police de la ligne d''invitation (jointure par req) ; null si la réponse n''est pas issue d''un lien personnalisé.';

-- --- Droits (perdus par le drop, à reposer) ----------------------------------
grant select on public.v_verbatims to authenticated;
