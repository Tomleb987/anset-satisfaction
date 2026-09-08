-- =============================================================================
--  ANSET — La vue de relance en production porte-t-elle bien tous les correctifs ?
--
--  POURQUOI CE FICHIER. La migration `20260903090000_relance_unique_par_personne`
--  a été appliquée à la main dans l'éditeur SQL (pas de `supabase login` possible
--  depuis le poste de développement), et elle a reçu deux correctifs tardifs — la
--  péremption à 90 jours et le `grant` à `service_role`. Rien ne garantit que la
--  version collée en prod soit la version finale, et une vue muette ne se
--  distingue pas d'une vue à jour en regardant l'application.
--
--  CE QU'IL LIT. La définition réelle de la vue telle que Postgres l'a stockée,
--  pas le fichier du dépôt. Les intervalles sont comparés dans la forme que
--  Postgres leur donne — `'6 mons'`, pas `'6 months'`.
--
--  TOUT DOIT ÊTRE `t`. Un seul `f` dit précisément ce qui manque.
-- =============================================================================

with d as (select pg_get_viewdef('public.v_relances_a_faire', true) as v)
select 'Delai J+7 (plancher)'                        as controle,
       (select v like '%''7 days''::interval%' from d) as ok
union all
select 'Plafond : un rappel par personne / 6 mois',
       (select v like '%''6 mons''::interval%' from d)
union all
select 'Peremption de l invitation a 90 jours',
       (select v like '%''90 days''::interval%' from d)
union all
select 'Une seule ligne par personne (distinct on email)',
       (select v like '%DISTINCT ON (email)%' from d)
union all
-- L'Edge Function lit la file avec la clé service_role, et `security_invoker`
-- fait lire la table de base sous le rôle appelant : sans ce SELECT, le cron
-- serait muet — 200 en apparence, personne relancé en réalité.
select 'service_role peut lire la file (le cron en depend)',
       exists (select 1 from information_schema.role_table_grants
                where table_name = 'v_relances_a_faire'
                  and grantee = 'service_role' and privilege_type = 'SELECT')
union all
select 'authenticated peut lire la file (onglet Administration)',
       exists (select 1 from information_schema.role_table_grants
                where table_name = 'v_relances_a_faire'
                  and grantee = 'authenticated' and privilege_type = 'SELECT')
union all
-- Le rôle anon a été révoqué le 11/08 après une fuite publique, et un
-- `create or replace view` conserve les grants. On teste `SELECT` et RIEN
-- D'AUTRE : `TRIGGER`, `REFERENCES` et `TRUNCATE` apparaissent souvent sans
-- permettre de lire, et un contrôle qui s'en alarme finit par être ignoré.
-- Première version de ce fichier : elle testait « aucun droit » et a crié au
-- loup en prod. Détail : scripts/controle_anon_lecture.sql.
select 'anon ne peut PAS lire la file (SELECT seul compte)',
       not exists (select 1 from information_schema.role_table_grants
                    where table_name = 'v_relances_a_faire'
                      and grantee = 'anon' and privilege_type = 'SELECT')
union all
select 'Index partiel idx_envois_email_relance present',
       exists (select 1 from pg_indexes
                where schemaname = 'public' and indexname = 'idx_envois_email_relance')
union all
select 'Ligne 20260903090000 dans schema_migrations',
       exists (select 1 from supabase_migrations.schema_migrations
                where version = '20260903090000');

-- Si un contrôle est `f`, relire la définition réelle pour voir ce qui a été posé :
-- select pg_get_viewdef('public.v_relances_a_faire', true);
