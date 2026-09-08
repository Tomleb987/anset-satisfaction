-- =============================================================================
--  ANSET — Quelles migrations du dépôt ne sont PAS en production ?
--
--  POURQUOI CE FICHIER EXISTE. Le 08/09/2026, deux migrations crues appliquées ne
--  l'étaient pas : `20260903090000` (plafond de relance) et, bien plus grave,
--  `20260811103000` (révocation des droits du rôle `anon`, restée ouverte un mois).
--  Ce n'est pas un accident isolé : ici les migrations se posent À LA MAIN dans
--  l'éditeur SQL — `supabase login` est impossible depuis l'environnement de
--  développement — donc rien ne rapproche le dépôt de la base. Aucun outil ne
--  prévient, et une migration manquante ne se voit pas : l'application continue de
--  fonctionner, avec l'ancienne règle.
--
--  À JOUER après chaque migration posée à la main, et au moindre doute.
--  `manquant = true` sur une ligne : coller le fichier correspondant depuis
--  `supabase/migrations/`, puis ajouter sa ligne de suivi :
--      insert into supabase_migrations.schema_migrations (version)
--      values ('<version>') on conflict do nothing;
--
--  Cette liste est celle du dépôt au 08/09/2026
--  (28 migrations). La régénérer :
--      ls supabase/migrations/*.sql
--
--  Lecture seule.
-- =============================================================================

with depot(version, fichier) as (values
  ('20260723090200', 'base_schema.sql'),
  ('20260723090300', 'agences.sql'),
  ('20260723090400', 'envois_sondage.sql'),
  ('20260723090500', 'reponses_dashboard.sql'),
  ('20260723090600', 'rls_app.sql'),
  ('20260724120000', 'motif_sinistre.sql'),
  ('20260724130000', 'reseaux_sociaux.sql'),
  ('20260724140000', 'sinistres_delai.sql'),
  ('20260725090000', 'conseillers_agence_nullable.sql'),
  ('20260729120000', 'profils_utilisateurs.sql'),
  ('20260729130000', 'admin_reserve_super_admin.sql'),
  ('20260729140000', 'attribution_coherente.sql'),
  ('20260729150000', 'zone_polynesie_assurances.sql'),
  ('20260729160000', 'csat_sinistre_indemnises.sql'),
  ('20260729170000', 'leads_prise_en_charge.sql'),
  ('20260729180000', 'delai_sinistre_median.sql'),
  ('20260729190000', 'bases_de_calcul.sql'),
  ('20260729200000', 'registre_consentements.sql'),
  ('20260730100000', 'role_conseiller.sql'),
  ('20260730120000', 'relance_j7.sql'),
  ('20260730180000', 'journal_relances.sql'),
  ('20260730190000', 'profils_lecture_restreinte.sql'),
  ('20260730200000', 'reinitialisation_mot_de_passe.sql'),
  ('20260731090000', 'conseillers_sans_reponse.sql'),
  ('20260811090000', 'verbatim_contrat.sql'),
  ('20260811103000', 'anon_sans_lecture.sql'),
  ('20260903090000', 'relance_unique_par_personne.sql'),
  ('20260908090000', 'attribution_redacteur.sql')
)
select d.version,
       d.fichier,
       (m.version is null) as manquant
  from depot d
  left join supabase_migrations.schema_migrations m on m.version = d.version
 order by d.version;
