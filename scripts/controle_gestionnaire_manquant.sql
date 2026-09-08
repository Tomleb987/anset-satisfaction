-- =============================================================================
--  ANSET — Pourquoi des envois n'ont pas de `gestionnaire_id`. RÉSOLU le 08/09/2026,
--  gardé parce que la question reviendra à chaque mois rebasculé.
--
--  CONTEXTE. La migration `20260908090000_attribution_redacteur` a recopié
--  `conseiller_id` dans la nouvelle colonne `gestionnaire_id`, pour que le
--  gestionnaire ne soit pas perdu quand la rebascule écrit le rédacteur par dessus.
--  Le contrôle a renvoyé 1 274 envois sans gestionnaire, dont 727 AVEC un
--  conseiller — ce qui ressemblait à une perte d'information.
--
--  CE N'EN ÉTAIT PAS UNE, et la démonstration vaut d'être gardée. Ces 727 envois
--  avaient la cellule « Gestionnaire » VIDE dans la requête mensuelle :
--  `conseiller_id` valait donc null avant la migration, le backfill a recopié null
--  (il n'avait rien à recopier), puis la rebascule a écrit le rédacteur dans
--  `conseiller_id`. Aucun gestionnaire n'a jamais existé sur ces lignes.
--
--  VÉRIFIÉ EN RECOMPTANT LES REQUÊTES, hors base : les lignes ayant un rédacteur
--  mais pas de gestionnaire sont 77 (juin) + 70 (juillet) + 579 (août) = 726, là où
--  la prod compte 78 + 71 + 578 = 727. Même ensemble, au bruit du dédoublonnage
--  par e-mail près.
--
--  CE QUI RESTE À SURVEILLER, et le seul chiffre qui doit être 0 : un envoi sans
--  gestionnaire, avec un conseiller que l'import n'explique pas. Ni cellule vide,
--  ni rebascule — donc une vraie anomalie. Piste : un envoi créé par un front qui
--  n'écrit pas `gestionnaire_id`.
--
--  À NOTER SUR LA QUALITÉ DE LA SOURCE : août compte 583 contrats sans
--  gestionnaire sur 5 163 (11,3 %), contre ~2,5 % en juin et juillet. Quelque
--  chose a changé dans la production de la requête d'août.
--
--  Lecture seule. À coller dans l'éditeur SQL Supabase.
-- =============================================================================

select 'D1. aucun conseiller, rien a recopier (benin)' as ligne,
       count(*)::text as valeur
  from public.envois_sondage
 where gestionnaire_id is null and conseiller_id is null

union all
select 'D2. cellule Gestionnaire vide, rebascule a mis le redacteur (benin)',
       count(*)::text
  from public.envois_sondage e
  join public.import_redacteur m on m.req = e.req
 where e.gestionnaire_id is null and e.conseiller_id = m.redacteur

union all
select 'D3. sans gestionnaire et INEXPLIQUE (doit etre 0)',
       count(*)::text
  from public.envois_sondage e
  left join public.import_redacteur m on m.req = e.req
 where e.gestionnaire_id is null
   and e.conseiller_id is not null
   and (m.req is null or e.conseiller_id <> m.redacteur)

union all
-- Répartition, pour situer. `coalesce` sur le motif : un import quittance écrit
-- `motif = null`, pas 'quittance' (satisfaction_anset.html:1885) — sans lui le
-- libellé entier devient nul et la ligne est illisible.
select 'D4. ' || e.campagne || ' / ' || coalesce(e.motif, 'quittance')
         || ' : ' || count(*) || ' sans gestionnaire, dont inexpliques',
       count(*) filter (
         where e.conseiller_id is not null
           and not exists (select 1 from public.import_redacteur m
                            where m.req = e.req and m.redacteur = e.conseiller_id)
       )::text
  from public.envois_sondage e
 where e.gestionnaire_id is null
 group by e.campagne, e.motif

order by ligne;
