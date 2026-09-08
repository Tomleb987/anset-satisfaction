-- =============================================================================
--  ANSET — Retirer les conseillers créés par la rebascule qui ne servent à rien.
--
--  D'OÙ ILS VIENNENT. `appliquer_redacteur()` crée un `conseillers` pour CHAQUE
--  rédacteur de `import_redacteur` (étape 3a) : la FK d'`envois_sondage` l'exige.
--  Or les requêtes mensuelles portent tous les contrats du mois — 19 479 lignes —
--  quand seule une fraction a reçu une invitation. Des rédacteurs qui n'ont jamais
--  servi un client sondé se retrouvent donc en base. 10 en prod au 08/09/2026.
--
--  CE QU'ILS COÛTENT, ET CE QU'ILS NE COÛTENT PAS. Ils n'apparaissent dans AUCUN
--  indicateur : `v_satisfaction_conseiller` se bâtit sur les envois et les
--  réponses, pas sur `conseillers` (vérifié : 0 ligne). Ils encombrent seulement la
--  liste de l'onglet Utilisateurs, au moment de créer des comptes.
--
--  POURQUOI LE CRITÈRE EST SI LONG. Cinq colonnes pointent vers `conseillers`, et
--  les quatre qui ont une FK sont en `ON DELETE SET NULL` :
--
--      envois_sondage.conseiller_id      leads.conseiller_id
--      profils.conseiller_id             leads.traite_par
--      reponses_satisfaction.conseiller_id   (sans FK, slug écrit tel quel)
--
--  Un `delete` qui en oublierait une ne lèverait AUCUNE erreur : la colonne
--  passerait à null, en silence. `leads.traite_par` est le cas qui m'avait échappé
--  — un conseiller peut avoir pris en charge un lead en prospection sans avoir la
--  moindre réponse à son nom, et le perdre effacerait qui a traité ce prospect.
--
--  À JOUER DANS L'ORDRE : le select d'abord, on regarde, le delete ensuite.
--  Ne pas jouer avant d'avoir lu la ligne F de controle_redacteur.sql : un mois de
--  requête encore manquant rendrait certains de ces noms légitimes plus tard.
-- =============================================================================

-- --- 1. LES VOIR AVANT DE LES PERDRE ----------------------------------------
-- `id` et `nom` seulement : la prod n'a PAS de colonne `created_at` sur
-- `conseillers`, alors qu'une base rejouée depuis les migrations l'a. Écart
-- local/prod constaté le 08/09/2026, de la même famille que celui des `grant`.
select c.id, c.nom
  from public.conseillers c
 where not exists (select 1 from public.envois_sondage       e where e.conseiller_id = c.id)
   and not exists (select 1 from public.reponses_satisfaction r where r.conseiller_id = c.id)
   and not exists (select 1 from public.profils              p where p.conseiller_id = c.id)
   and not exists (select 1 from public.leads                l where l.conseiller_id = c.id)
   and not exists (select 1 from public.leads                l where l.traite_par    = c.id)
 order by c.id;

-- --- 2. LES RETIRER ---------------------------------------------------------
-- `returning` pour garder la trace de ce qui est parti : la liste s'affiche, et
-- elle doit être exactement celle du select ci-dessus.
delete from public.conseillers c
 where not exists (select 1 from public.envois_sondage       e where e.conseiller_id = c.id)
   and not exists (select 1 from public.reponses_satisfaction r where r.conseiller_id = c.id)
   and not exists (select 1 from public.profils              p where p.conseiller_id = c.id)
   and not exists (select 1 from public.leads                l where l.conseiller_id = c.id)
   and not exists (select 1 from public.leads                l where l.traite_par    = c.id)
returning c.id, c.nom;
