-- =============================================================================
--  ANSET — Libellé de zone « Polynésie Assurance » → « Polynésie Assurances ».
--  Le nom de l'agence porte le « s », la zone l'avait perdu : deux libellés pour
--  une même entité, visibles côte à côte dans le dashboard (vue par zone vs vue
--  par agence). Le seed de `20260723090300_agences.sql` est corrigé à la source ;
--  cette migration reprend les données déjà écrites.
--  Idempotent : rejouable sans effet une fois la reprise faite.
-- =============================================================================

update public.agences
   set zone = 'Polynésie Assurances'
 where zone = 'Polynésie Assurance';

update public.envois_sondage
   set zone = 'Polynésie Assurances'
 where zone = 'Polynésie Assurance';

update public.reponses_satisfaction
   set zone = 'Polynésie Assurances'
 where zone = 'Polynésie Assurance';
