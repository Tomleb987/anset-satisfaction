-- =============================================================================
-- ANSET — conseillers.agence : autoriser NULL.
-- Un gestionnaire issu de l'import « sinistres clos » (pôle sinistres) n'a pas
-- forcément d'agence commerciale ; l'import le crée alors sans agence.
-- La contrainte NOT NULL héritée de la config initiale faisait échouer l'insert.
-- Idempotent (drop not null est sans effet si déjà nullable).
-- =============================================================================

alter table public.conseillers alter column agence drop not null;
