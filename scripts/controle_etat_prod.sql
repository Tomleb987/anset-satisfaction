-- =============================================================================
--  ANSET — État de la production, en un seul résultat. LE contrôle à jouer.
--
--  POURQUOI IL EXISTE. Les migrations se posent à la main dans l'éditeur SQL
--  (`supabase login` impossible depuis l'environnement de développement), donc
--  rien ne rapproche le dépôt de la base et l'éditeur ne signale pas un collage
--  qui n'a pas pris. Le 08/09/2026, quatre migrations étaient crues appliquées
--  sans l'être — dont la révocation des droits du rôle `anon`, restée ouverte un
--  mois, et le plafond de relance dont le front annonçait déjà la règle.
--
--  Une base en retard ne se voit pas : l'application tourne, avec l'ancienne
--  règle, et affiche des chiffres plausibles. Ce fichier est le seul moyen de
--  savoir. À jouer après chaque migration posée à la main.
--
--  TOUT DOIT ÊTRE `t`. Un `f` nomme précisément ce qui manque.
--  Lecture seule.
-- =============================================================================

with depot(version, fichier) as (values
  ('20260723090200','base_schema.sql'),
  ('20260723090300','agences.sql'),
  ('20260723090400','envois_sondage.sql'),
  ('20260723090500','reponses_dashboard.sql'),
  ('20260723090600','rls_app.sql'),
  ('20260724120000','motif_sinistre.sql'),
  ('20260724130000','reseaux_sociaux.sql'),
  ('20260724140000','sinistres_delai.sql'),
  ('20260725090000','conseillers_agence_nullable.sql'),
  ('20260729120000','profils_utilisateurs.sql'),
  ('20260729130000','admin_reserve_super_admin.sql'),
  ('20260729140000','attribution_coherente.sql'),
  ('20260729150000','zone_polynesie_assurances.sql'),
  ('20260729160000','csat_sinistre_indemnises.sql'),
  ('20260729170000','leads_prise_en_charge.sql'),
  ('20260729180000','delai_sinistre_median.sql'),
  ('20260729190000','bases_de_calcul.sql'),
  ('20260729200000','registre_consentements.sql'),
  ('20260730100000','role_conseiller.sql'),
  ('20260730120000','relance_j7.sql'),
  ('20260730180000','journal_relances.sql'),
  ('20260730190000','profils_lecture_restreinte.sql'),
  ('20260730200000','reinitialisation_mot_de_passe.sql'),
  ('20260731090000','conseillers_sans_reponse.sql'),
  ('20260811090000','verbatim_contrat.sql'),
  ('20260811103000','anon_sans_lecture.sql'),
  ('20260903090000','relance_unique_par_personne.sql'),
  ('20260908090000','attribution_redacteur.sql')
), d as (select pg_get_viewdef('public.v_relances_a_faire', true) as v)

-- --- 1. Le dépôt et la base disent-ils la même chose ? ----------------------
select 'MIGRATION ' || d2.version || ' — ' || d2.fichier as controle,
       exists (select 1 from supabase_migrations.schema_migrations m
                where m.version = d2.version) as ok
  from depot d2

-- --- 2. La vue de relance porte-t-elle ses trois délais ? -------------------
union all select 'RELANCE plancher J+7',        (select v like '%''7 days''::interval%'  from d)
union all select 'RELANCE plafond 6 mois',      (select v like '%''6 mons''::interval%'  from d)
union all select 'RELANCE peremption 90 jours', (select v like '%''90 days''::interval%' from d)
union all select 'RELANCE une ligne par personne (distinct on)',
                 (select v like '%DISTINCT ON (email)%' from d)
union all select 'RELANCE index partiel idx_envois_email_relance',
                 exists (select 1 from pg_indexes
                          where schemaname = 'public'
                            and indexname = 'idx_envois_email_relance')

-- --- 3. Le numéro de contrat sous le verbatim (l'app lit `v.contrat`) -------
union all select 'VERBATIM colonne contrat presente',
                 exists (select 1 from information_schema.columns
                          where table_schema = 'public' and table_name = 'v_verbatims'
                            and column_name = 'contrat')

-- --- 4. Le rôle public ne lit plus rien ------------------------------------
union all select 'ANON ne peut lire AUCUN objet de public',
                 not exists (select 1 from information_schema.role_table_grants
                              where table_schema = 'public' and grantee = 'anon'
                                and privilege_type = 'SELECT')
-- Deux jeux de privilèges par défaut coexistent sur les tables de `public` :
-- celui de `supabase_admin`, qui accorde TOUT à `anon` et qu'on ne peut pas
-- changer, et celui de `postgres`, que la migration du 11/08 corrige. Comme les
-- migrations et l'éditeur SQL s'exécutent en `postgres`, c'est ce second jeu qui
-- gouverne les objets qu'on crée. On exige donc qu'il EXISTE et qu'il ignore
-- `anon` — sa seule absence ne prouverait rien.
union all select 'ANON exclu des privileges par defaut (objets futurs)',
                 exists (
                   select 1 from pg_default_acl da
                    join pg_namespace n on n.oid = da.defaclnamespace
                    join pg_roles   r on r.oid = da.defaclrole
                   where n.nspname = 'public' and da.defaclobjtype = 'r'
                     and r.rolname = 'postgres'
                     and array_to_string(da.defaclacl, ',') not like '%anon=%')

-- --- 5. Une seule vue a le droit d'ignorer la RLS --------------------------
-- `v_satisfaction_reseau` est en invoker OFF volontairement (repère de
-- comparaison des comptes conseiller). Toute AUTRE vue en invoker OFF n'est
-- protégée que par ses grants — c'est ainsi que la fuite du 11/08 est arrivée.
union all select 'RLS : aucune vue en invoker OFF hormis v_satisfaction_reseau',
                 not exists (
                   select 1 from pg_class c
                    where c.relnamespace = 'public'::regnamespace and c.relkind = 'v'
                      and c.relname <> 'v_satisfaction_reseau'
                      and coalesce(c.reloptions::text, '') not like '%security_invoker=on%'
                      and coalesce(c.reloptions::text, '') not like '%security_invoker=true%')

order by controle;
