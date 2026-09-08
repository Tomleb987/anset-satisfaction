-- =============================================================================
--  ANSET — Que peut LIRE le rôle `anon` ? (clé publishable, donc public)
--
--  POURQUOI CE CONTRÔLE EXISTE. Le 11/08/2026, `v_satisfaction_reseau` était
--  lisible par `anon` : n'importe qui muni de la clé publishable — elle est dans
--  le HTML du formulaire — pouvait lire l'agrégat. **La RLS ne s'applique pas aux
--  vues** : une vue accessible à `anon` est une lecture publique, point. Les droits
--  d'`anon` ont été révoqués ce jour-là (`20260811103000_anon_sans_lecture`).
--
--  CE QU'IL FAUT DISTINGUER, et que mon premier contrôle confondait : `TRIGGER`,
--  `REFERENCES` et `TRUNCATE` apparaissent souvent sur un rôle sans qu'il puisse
--  lire quoi que ce soit. **Seul `SELECT` est une fuite.** Un contrôle qui
--  s'alarme de n'importe quel privilège finit par être ignoré.
--
--  Lecture seule.
-- =============================================================================

-- --- 1. Le détail sur la file de relance ------------------------------------
-- Elle porte e-mail, prénom, nom, agence, conseiller et motif de clients qui
-- n'ont pas répondu. `anon` ne doit y figurer avec AUCUN `SELECT`.
select grantee, privilege_type
  from information_schema.role_table_grants
 where table_schema = 'public' and table_name = 'v_relances_a_faire'
   and grantee in ('anon','authenticated','service_role')
 order by grantee, privilege_type;

-- --- 2. LE BALAYAGE QUI COMPTE ----------------------------------------------
-- Toute table ou vue de `public` que `anon` peut lire. Doit renvoyer 0 ligne.
--
-- LA COLONNE `verdict` FAIT LA DIFFÉRENCE ENTRE UN DROIT ET UNE FUITE :
--
--   · BASE TABLE            → la RLS s'applique encore. `anon` n'a aucune policy
--                             dans ce projet, donc la table répond 200 avec une
--                             liste vide. À révoquer quand même (une policy posée
--                             plus tard ouvrirait tout), mais rien n'a fuité.
--   · VIEW, invoker ON      → la vue lit ses tables sous le rôle appelant, donc
--                             la RLS d'`anon` s'applique : liste vide elle aussi.
--   · VIEW, invoker OFF     → **FUITE RÉELLE.** Aucune RLS ne s'applique, le grant
--                             `anon` était le seul verrou. C'est exactement le cas
--                             de `v_satisfaction_reseau` le 11/08/2026, posée en
--                             invoker OFF volontairement (elle sert de repère aux
--                             comptes conseiller) : elle rendait les chiffres du
--                             réseau à n'importe qui.
--
-- Remède unique et complet : appliquer `20260811103000_anon_sans_lecture.sql`, qui
-- révoque tout ET corrige les privilèges par défaut, sans quoi la prochaine vue
-- créée retrouvera le grant en silence.
select t.table_type,
       t.table_name,
       case
         when t.table_type = 'BASE TABLE' then 'droit inutile, RLS bloque encore'
         when coalesce(c.reloptions::text, '') like '%security_invoker=on%'
           or coalesce(c.reloptions::text, '') like '%security_invoker=true%'
              then 'droit inutile, RLS de la table s applique'
         else 'FUITE : aucune RLS ne s applique a cette vue'
       end as verdict
  from information_schema.tables t
  join information_schema.role_table_grants g
    on g.table_schema = t.table_schema and g.table_name = t.table_name
  left join pg_class c
    on c.relname = t.table_name
   and c.relnamespace = 'public'::regnamespace
 where t.table_schema = 'public'
   and g.grantee = 'anon' and g.privilege_type = 'SELECT'
 order by verdict desc, t.table_type, t.table_name;
