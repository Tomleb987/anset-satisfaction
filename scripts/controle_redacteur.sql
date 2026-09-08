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
-- D se lit en deux : un envoi sans AUCUN conseiller n'a jamais eu de gestionnaire
-- à perdre (bénin, la migration du 08/09 ne pouvait rien recopier). Un envoi QUI A
-- un conseiller mais pas de gestionnaire, lui, a perdu l'information.
select 'D1. sans gestionnaire NI conseiller (benin)',
       count(*)::text from public.envois_sondage
      where gestionnaire_id is null and conseiller_id is null
union all
select 'D2. gestionnaire PERDU alors qu il y a un conseiller (doit etre 0)',
       count(*)::text from public.envois_sondage
      where gestionnaire_id is null and conseiller_id is not null
union all
-- Ils n'apparaissent dans AUCUN indicateur (vérifié : 0 ligne dans
-- v_satisfaction_conseiller, qui se bâtit sur les envois et les réponses, pas sur
-- `conseillers`) — ils encombrent seulement le menu de création de comptes.
select 'E. conseillers sans aucune activite (les fantomes)',
       count(*)::text from public.conseillers c
      where not exists (select 1 from public.envois_sondage e where e.conseiller_id = c.id)
        and not exists (select 1 from public.reponses_satisfaction r where r.conseiller_id = c.id)
        and not exists (select 1 from public.profils p where p.conseiller_id = c.id)
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

-- Pour voir les fantômes de la ligne E avant d'en décider :
-- select c.id, c.nom from public.conseillers c
--  where not exists (select 1 from public.envois_sondage e where e.conseiller_id = c.id)
--    and not exists (select 1 from public.reponses_satisfaction r where r.conseiller_id = c.id)
--    and not exists (select 1 from public.profils p where p.conseiller_id = c.id)
--  order by c.id;

-- Et pour les retirer. NE PAS jouer avant d'avoir lu la ligne F : un mois de
-- requête encore manquant en rendra certains légitimes plus tard.
-- delete from public.conseillers c
--  where not exists (select 1 from public.envois_sondage e where e.conseiller_id = c.id)
--    and not exists (select 1 from public.reponses_satisfaction r where r.conseiller_id = c.id)
--    and not exists (select 1 from public.profils p where p.conseiller_id = c.id);
