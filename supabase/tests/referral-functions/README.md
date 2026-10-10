# Banc d'essai local des fonctions de parrainage

Exécute le **vrai code** de `referral-document` et `notify-referral` contre une base
PostgreSQL locale jetable (migrations rejouées + `0134` + scénarios de
`../0134_referral_transparency_test.sql`). Aucun appel à Supabase, à Resend ni à la production :
`supabase_stub.ts` remplace supabase-js (requêtes SQL avec les droits de l'utilisateur ou de
service), le stockage est un dossier local et l'envoi d'e-mails est intercepté.

```
PGHOST=... PGPORT=... PGDATABASE=... deno run -A --config=deno.json --import-map=import_map_run.json run.ts
```
