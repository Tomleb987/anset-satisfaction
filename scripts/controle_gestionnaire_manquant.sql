-- =============================================================================
--  ANSET — Pourquoi 1 274 envois n'ont pas de `gestionnaire_id`.
--
--  CONTEXTE. La migration du 08/09/2026 (`20260908090000_attribution_redacteur`)
--  a recopié `conseiller_id` dans la nouvelle colonne `gestionnaire_id`, pour que
--  le gestionnaire ne soit pas perdu quand la rebascule écrit le rédacteur par
--  dessus. Le contrôle D de `controle_redacteur.sql` a renvoyé 1 274 au lieu de 0.
--
--  CE QUE CE FICHIER DÉMÊLE. Le chiffre brut mélange deux situations qui n'ont
--  rien à voir :
--
--    D1 — l'envoi n'a AUCUN conseiller. Il n'a donc jamais eu de gestionnaire à
--         perdre : la migration n'avait rien à recopier. Bénin, et attendu — un
--         import dont la cellule gestionnaire était vide donne exactement ça.
--
--    D2 — l'envoi A un conseiller mais pas de gestionnaire. Là l'information a
--         bien disparu. DOIT ÊTRE 0. Si ce n'est pas 0, deux pistes : des envois
--         créés APRÈS la migration par un front pas encore déployé (il n'écrit
--         pas `gestionnaire_id`), ou la rebascule qui aurait écrit un rédacteur
--         sur une ligne que le backfill n'avait pas couverte.
--
--    D3 — la répartition par campagne. Si tout est concentré sur les campagnes
--         les plus anciennes, c'est un import antérieur au suivi du gestionnaire
--         et l'affaire est close. Si ça touche la campagne en cours, voir D2.
--
--  Lecture seule. À coller dans l'éditeur SQL Supabase.
-- =============================================================================

select 'D1. sans gestionnaire NI conseiller (benin)' as ligne,
       count(*)::text as valeur
  from public.envois_sondage
 where gestionnaire_id is null and conseiller_id is null

union all
select 'D2. gestionnaire PERDU alors qu il y a un conseiller (doit etre 0)',
       count(*)::text
  from public.envois_sondage
 where gestionnaire_id is null and conseiller_id is not null

union all
-- `coalesce` sur le motif : un import quittance écrit `motif = null`, pas
-- 'quittance' (satisfaction_anset.html:1885). Sans lui, le libellé entier devient
-- nul et la ligne est illisible — le piège rencontré sur la ligne F.
select 'D3. ' || e.campagne || ' / ' || coalesce(e.motif, 'quittance')
         || ' : ' || count(*) || ' envois sans gestionnaire, dont avec conseiller',
       count(*) filter (where e.conseiller_id is not null)::text
  from public.envois_sondage e
 where e.gestionnaire_id is null
 group by e.campagne, e.motif

order by ligne;
