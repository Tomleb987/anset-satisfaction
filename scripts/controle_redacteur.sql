-- =============================================================================
--  ANSET — Contrôle de la rebascule vers le rédacteur.
--
--  À JOUER dans l'éditeur SQL Supabase après chaque chargement de
--  `import_redacteur` (cf. scripts/redacteur_mapping.py), et à rejouer chaque fois
--  qu'une requête mensuelle arrive en retard. Lecture seule — le seul `delete` est
--  commenté en fin de fichier.
--
--  CE QU'IL CHERCHE, ET POURQUOI IL EXISTE. La colonne « Redacteur » des requêtes
--  mensuelles n'a jamais été lue avant le 08/09/2026 : la correspondance
--  `req → rédacteur` des mois déjà diffusés n'existe que dans les .xlsx. Un mois
--  dont la requête n'a jamais été fournie laisse ses réponses au crédit du
--  GESTIONNAIRE, et rien ne le signale — le classement reste plausible, il crédite
--  simplement le mauvais conseiller. C'est la ligne F qui le révèle.
--
--  Tout tient dans un seul résultat, pour être recollé d'un bloc.
-- =============================================================================

select 'A. correspondances chargees' as ligne,
       count(*)::text as valeur from public.import_redacteur
union all
select 'B. envois quittance en desaccord avec l import (doit etre 0)',
       count(*)::text from public.envois_sondage e
       join public.import_redacteur m on m.req = e.req
      where e.motif <> 'sinistre' and e.conseiller_id <> m.redacteur
union all
select 'C. sinistres touches a tort (doit etre 0)',
       count(*)::text from public.envois_sondage
      where motif = 'sinistre' and conseiller_id is distinct from gestionnaire_id
union all
-- D SE LIT EN TROIS. Mesuré en prod le 08/09/2026 : 547 / 727 / 0.
--
--   D1 — aucun conseiller : rien à recopier, la cellule « Gestionnaire » ET la
--        cellule « Redacteur » étaient vides. Bénin.
--   D2 — un conseiller égal au rédacteur de l'import : la cellule
--        « Gestionnaire » était vide, `conseiller_id` valait donc null avant, le
--        backfill a recopié null, puis la rebascule a écrit le rédacteur. Rien
--        n'a été perdu — il n'y avait pas de gestionnaire. Bénin AUSSI, et c'est
--        le gros du chiffre : 727 sur 1 274, confirmé en recomptant les requêtes
--        (77 + 70 + 579 lignes « rédacteur sans gestionnaire »).
--   D3 — un conseiller que l'import n'explique pas. LE SEUL À SURVEILLER : ni
--        cellule vide, ni rebascule. Piste : un envoi créé par un front qui
--        n'écrit pas `gestionnaire_id`.
select 'D1. aucun conseiller, rien a recopier (benin)',
       count(*)::text from public.envois_sondage
      where gestionnaire_id is null and conseiller_id is null
union all
select 'D2. cellule Gestionnaire vide, rebascule a mis le redacteur (benin)',
       count(*)::text from public.envois_sondage e
       join public.import_redacteur m on m.req = e.req
      where e.gestionnaire_id is null and e.conseiller_id = m.redacteur
union all
select 'D3. sans gestionnaire et INEXPLIQUE (doit etre 0)',
       count(*)::text from public.envois_sondage e
       left join public.import_redacteur m on m.req = e.req
      where e.gestionnaire_id is null
        and e.conseiller_id is not null
        and (m.req is null or e.conseiller_id <> m.redacteur)
union all
-- Ils n'apparaissent dans AUCUN indicateur (vérifié : 0 ligne dans
-- v_satisfaction_conseiller, qui se bâtit sur les envois et les réponses, pas sur
-- `conseillers`) — ils encombrent seulement le menu de création de comptes.
select 'E. conseillers sans aucune activite (les fantomes)',
       count(*)::text from public.conseillers c
      where not exists (select 1 from public.envois_sondage e where e.conseiller_id = c.id)
        and not exists (select 1 from public.reponses_satisfaction r where r.conseiller_id = c.id)
        and not exists (select 1 from public.profils p where p.conseiller_id = c.id)
        -- `leads` compte AUSSI, et par deux colonnes : les quatre FK vers
        -- `conseillers` sont en ON DELETE SET NULL, donc un critère incomplet
        -- ferait passer pour fantôme quelqu'un dont la suppression viderait
        -- `traite_par` en silence. Cf. scripts/supprimer_conseillers_fantomes.sql.
        and not exists (select 1 from public.leads l where l.conseiller_id = c.id)
        and not exists (select 1 from public.leads l where l.traite_par = c.id)
union all
-- LA LIGNE QUI COMPTE. Par campagne, le % de `req` absents de l'import :
--   · quelques %          → NORMAL, cellule « Redacteur » vide (204 lignes sur
--                            les 19 479 des requêtes juin/juillet/août) ; sans
--                            rédacteur connu le gestionnaire reste en place.
--   · proche de 100 %     → LA REQUÊTE DU MOIS MANQUE. La redemander, puis
--                            rejouer redacteur_mapping.py sur TOUS les mois.
--   · motif 'sinistre'    → écarté volontairement, ignorer la ligne. Attendu très
--                            haut, mais PAS 100 % : quelques `req` sinistre entrent
--                            dans l'import par collision de clé `Dossier`, et la
--                            fonction les écarte (reqs_ignores_sin).
--   · motif 'quittance'   → en base c'est NULL, pas 'quittance' (l'import écrit
--                            `motif: isSin ? "sinistre" : null`). D'où le
--                            `coalesce` ci-dessous : sans lui le libellé entier
--                            devient nul et la ligne devient illisible.
--   · campagne postérieure au 08/09/2026 → l'import porte déjà le rédacteur.
select 'F. ' || e.campagne || ' / ' || coalesce(e.motif, 'quittance') || ' : ' || count(*) || ' envois, manquants',
       round(100.0 * count(*) filter (where m.req is null) / count(*), 1)::text || ' %'
  from public.envois_sondage e
  left join public.import_redacteur m on m.req = e.req
 group by e.campagne, e.motif
 order by ligne;

-- Et pour les retirer : voir scripts/supprimer_conseillers_fantomes.sql, qui porte
-- le critère complet (les cinq colonnes qui pointent vers `conseillers`) et montre
-- la liste avant de la supprimer.
