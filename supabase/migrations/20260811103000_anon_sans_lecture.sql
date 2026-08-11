-- =============================================================================
--  ANSET — Le rôle `anon` ne lit plus rien dans `public`.
--
--  CONSTAT (11/08/2026, sondé sur la prod avec la clé publiable, qui est en clair
--  dans satisfaction_anset.html donc à la portée de tous) : les 21 tables et vues
--  de `public` répondaient 200 à un appelant ANONYME. Vingt d'entre elles rendaient
--  une liste vide — la RLS faisait son travail — mais `v_satisfaction_reseau`
--  rendait bel et bien les chiffres du réseau (réponses, NPS, taux) : elle est en
--  `security_invoker = off` (20260730100000, volontaire : elle sert de repère de
--  comparaison aux comptes conseiller, dont la RLS restreint les lignes sources),
--  donc AUCUNE RLS ne s'y applique. Le grant `anon` était le seul verrou, et il
--  était ouvert.
--
--  RÈGLE : `anon` n'a aucun usage de PostgREST dans ce projet. Le formulaire public
--  (sondage.html) fait UN appel, vers l'Edge Function submit-sondage, qui écrit en
--  service_role ; la réinitialisation de mot de passe est entièrement serveur
--  (Edge Function mot-de-passe-oublie) et le client ne touche jamais
--  `jetons_mot_de_passe` ; `boot()` n'appelle que sb.auth.getSession(), qui passe
--  par GoTrue et non par PostgREST. Tous les sb.from(...) sont derrière la session.
--  Vérifié avant écriture de cette migration.
--
--  On ne se repose donc plus sur la seule RLS pour les données nominatives
--  (verbatims, leads, envois, registre des consentements, jetons) : le rôle
--  anonyme n'a plus le droit d'ouvrir la porte, RLS ou pas. Cela rattrape aussi la
--  prochaine vue qu'on poserait en `security_invoker = off` sans y penser.
--
--  Ne PAS confondre avec `authenticated` : le dashboard, l'import et la prospection
--  passent tous par lui et ne sont pas touchés.
--  Additif, idempotent.
-- =============================================================================

-- --- Objets existants --------------------------------------------------------
-- `all tables` couvre aussi les vues. `all privileges` et pas seulement select :
-- les privilèges par défaut de Supabase accordent l'écriture au même titre, et
-- `anon` n'a pas plus à écrire qu'à lire.
revoke all privileges on all tables in schema public from anon;

-- --- Objets futurs -----------------------------------------------------------
-- Sans ceci, la prochaine vue créée par une migration retrouverait le grant `anon`
-- des privilèges par défaut du projet, et le durcissement se déferait en silence.
-- Ne s'applique qu'aux objets créés par le rôle qui exécute cette ligne (postgres,
-- celui des migrations et de l'éditeur SQL).
alter default privileges in schema public revoke all privileges on tables from anon;

-- --- Ce qui reste volontairement ouvert --------------------------------------
-- `usage` sur le schéma : PostgREST en a besoin pour répondre proprement (403
-- plutôt qu'une erreur de connexion), et il n'expose aucune donnée par lui-même.
grant usage on schema public to anon;
