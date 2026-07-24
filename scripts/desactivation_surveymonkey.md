# Désactivation SurveyMonkey

Suite à l'abandon de SurveyMonkey pour la collecte (formulaire HTML → `submit-sondage`).

## État constaté (inspection du 2026-07-23)

- **Aucun cron planifié** sur le projet (`select * from cron.job;` → vide). Il n'y a donc **rien à `unschedule`** — le job `sync-sondage-leads` évoqué dans la spec n'existe pas sur ce projet.
- Edge Function `sondage-lead-intake` : **déployée mais dormante** (aucun déclencheur). Elle ne s'exécute jamais.

## Actions

1. **Ne rien planifier** de SurveyMonkey (déjà le cas).
2. Optionnel — supprimer la fonction dormante :
   ```
   supabase functions delete sondage-lead-intake
   ```
   (ou la laisser : sans cron ni appel, elle est inerte.)
3. **Gain RGPD — révoquer le token SurveyMonkey** (SurveyMonkey → Settings → Apps) :
   plus aucun transfert de données hors UE. Retirer aussi les secrets devenus inutiles :
   ```
   supabase secrets unset SURVEYMONKEY_TOKEN SURVEY_ID
   ```

## Si un jour un cron de poll avait été créé

```sql
select cron.unschedule('sync-sondage-leads')
where exists (select 1 from cron.job where jobname = 'sync-sondage-leads');
```
