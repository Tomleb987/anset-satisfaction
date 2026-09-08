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
-- Chaque ligne rendue est une lecture publique, à révoquer :
--     revoke select on public.<objet> from anon;
select t.table_type, t.table_name
  from information_schema.tables t
  join information_schema.role_table_grants g
    on g.table_schema = t.table_schema and g.table_name = t.table_name
 where t.table_schema = 'public'
   and g.grantee = 'anon' and g.privilege_type = 'SELECT'
 order by t.table_type, t.table_name;
