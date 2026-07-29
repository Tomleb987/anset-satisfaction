// =============================================================================
// ANSET — Edge Function `envoi-sondage`  (verify_jwt=true : manager/service)
// -----------------------------------------------------------------------------
// Envoie les invitations au sondage via le RELAIS SMTP Brevo, à partir de la
// table `envois_sondage` (lignes statut_envoi='a_envoyer' de la campagne du mois).
// Chaque invitation porte un LIEN PERSONNALISÉ (agence, conseiller, req, motif) →
// réponse rattachée + lead pré-attribué.
//
// POURQUOI SMTP ET PLUS L'API : Brevo bloque les appels API venant d'une IP
// inconnue et l'IP de sortie des Edge Functions change à chaque invocation
// (liste blanche impossible). Les clés SMTP, elles, ne sont pas soumises à ce
// filtrage IP. Conséquences assumées de ce choix :
//   - pas de template transactionnel Brevo : le HTML est construit ici
//     (voir `email.ts`, source de vérité du visuel) ;
//   - pas de programmation H+2 (`scheduledAt` est une fonctionnalité de l'API) :
//     l'envoi part immédiatement.
//
// Idempotent : une ligne passée à 'envoye' n'est jamais renvoyée.
//
// Modes (query string) :
//   (défaut)          envoie le lot 'a_envoyer' de la campagne courante
//   ?campagne=YYYY-MM cible une campagne précise
//   ?limit=N          plafonne le lot (défaut 500)
//   ?dry=1            simule : ne contacte pas Brevo, ne modifie rien
//   ?test=a@b.pf      TEST : envoie 1 invitation à cette adresse, ne modifie rien
//
// Secrets/env : BREVO_SMTP_LOGIN, BREVO_SMTP_KEY, BREVO_SENDER_EMAIL,
//               BREVO_SENDER_NAME (optionnel, défaut "ANSET"), FORM_URL,
//               SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY (auto).
// Env optionnels : BREVO_SMTP_HOST (défaut smtp-relay.brevo.com),
//                  BREVO_SMTP_PORT (défaut 587), ALLOWED_ORIGIN (défaut "*").
// =============================================================================

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import nodemailer from "npm:nodemailer@^9";
import { SUJET, htmlInvitation, texteInvitation } from "./email.ts";

const ALLOWED_ORIGIN = Deno.env.get("ALLOWED_ORIGIN") ?? "*";

// Appelée depuis le dashboard avec un header Authorization : le navigateur
// envoie un préflight OPTIONS, qu'il faut autoriser explicitement.
const CORS = {
  "Access-Control-Allow-Origin": ALLOWED_ORIGIN,
  "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
  "Access-Control-Allow-Headers": "authorization, apikey, content-type",
  "Access-Control-Max-Age": "86400",
};

const json = (obj: unknown, status = 200) =>
  new Response(JSON.stringify(obj, null, 2), { status, headers: { ...CORS, "Content-Type": "application/json" } });

interface EnvoiRow {
  id: string;
  req: string | null;
  email: string | null;
  prenom: string | null;
  nom: string | null;
  agence: string | null;
  conseiller_id: string | null;
  motif: string | null;
}

/** Construit le lien personnalisé du formulaire. */
function lienPersonnalise(formUrl: string, row: EnvoiRow): string {
  const u = new URL(formUrl);
  if (row.agence) u.searchParams.set("agence", row.agence);
  if (row.conseiller_id) u.searchParams.set("conseiller", row.conseiller_id);
  if (row.req) u.searchParams.set("req", row.req);
  // Campagne typée (ex. sinistres clos) : le motif pré-remplit et adapte le questionnaire.
  if (row.motif) u.searchParams.set("motif", row.motif);
  return u.toString();
}

/** Adresse « From » au format RFC (nom affiché + adresse validée côté Brevo). */
function expediteur(name: string, email: string): string {
  return `"${name.replace(/"/g, "")}" <${email}>`;
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });

  const url = new URL(req.url);
  const dry = url.searchParams.get("dry") === "1";
  const testEmail = url.searchParams.get("test");
  const limit = Math.min(parseInt(url.searchParams.get("limit") ?? "500", 10) || 500, 2000);

  const now = new Date();
  const campagne = url.searchParams.get("campagne") ?? now.toISOString().slice(0, 7);

  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const serviceRole = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  // .trim() : un espace ou un saut de ligne collé dans le champ secret est
  // invisible dans l'UI et fait échouer l'authentification SMTP.
  const smtpHost = Deno.env.get("BREVO_SMTP_HOST")?.trim() || "smtp-relay.brevo.com";
  const smtpPort = parseInt(Deno.env.get("BREVO_SMTP_PORT")?.trim() ?? "587", 10) || 587;
  const smtpLogin = Deno.env.get("BREVO_SMTP_LOGIN")?.trim();
  const smtpKey = Deno.env.get("BREVO_SMTP_KEY")?.trim();
  const formUrl = Deno.env.get("FORM_URL")?.trim();
  const senderEmail = Deno.env.get("BREVO_SENDER_EMAIL")?.trim();
  const senderName = Deno.env.get("BREVO_SENDER_NAME")?.trim() || "ANSET";

  if (!supabaseUrl || !serviceRole) return json({ ok: false, error: "Config Supabase incomplète." }, 500);
  if (!formUrl) return json({ ok: false, error: "FORM_URL manquant." }, 500);
  // En SMTP l'expéditeur n'est plus porté par le template : il devient obligatoire.
  if (!dry && (!smtpLogin || !smtpKey)) {
    return json({ ok: false, error: "BREVO_SMTP_LOGIN ou BREVO_SMTP_KEY manquant." }, 500);
  }
  if (!dry && !senderEmail) return json({ ok: false, error: "BREVO_SENDER_EMAIL manquant." }, 500);

  const supabase = createClient(supabaseUrl, serviceRole, { auth: { persistSession: false } });

  // Lot à traiter.
  const { data: rows, error } = await supabase
    .from("envois_sondage")
    .select("id, req, email, prenom, nom, agence, conseiller_id, motif")
    .eq("campagne", campagne)
    .eq("statut_envoi", "a_envoyer")
    .not("email", "is", null)
    .limit(testEmail ? 1 : limit);
  if (error) return json({ ok: false, error: error.message }, 500);
  if (!rows || rows.length === 0) {
    // En test, l'absence de lot est un échec : le lien de test se construit à partir d'une ligne réelle.
    if (testEmail) {
      return json({
        ok: false, test: true, campagne,
        error: `Aucune ligne « à envoyer » pour la campagne ${campagne} : impossible de construire le lien de test. Importe un lot ou change de campagne.`,
      }, 409);
    }
    return json({ ok: true, campagne, traites: 0, message: "Aucun envoi 'a_envoyer'." });
  }

  // --- Mode DRY : aperçu, aucune connexion SMTP, aucune écriture.
  if (dry) {
    if (testEmail) {
      const r = rows[0] as EnvoiRow;
      return json({ ok: true, test: true, dry: true, to: testEmail, lien: lienPersonnalise(formUrl, r) });
    }
    return json({
      ok: true, dry: true, campagne, aTraiter: rows.length,
      apercu: (rows as EnvoiRow[]).slice(0, 5).map((r) => ({ email: r.email, prenom: r.prenom, lien: lienPersonnalise(formUrl, r) })),
    });
  }

  // Une seule connexion réutilisée pour tout le lot (Brevo limite les connexions
  // simultanées : maxConnections=1, envois séquentiels).
  const transport = nodemailer.createTransport({
    host: smtpHost,
    port: smtpPort,
    secure: smtpPort === 465,      // 465 = TLS direct ; 587 = STARTTLS
    requireTLS: smtpPort !== 465,  // refuse un 587 qui resterait en clair
    auth: { user: smtpLogin!, pass: smtpKey! },
    pool: true,
    maxConnections: 1,
  });
  const from = expediteur(senderName, senderEmail!);

  /** Envoie une invitation. Retourne l'erreur SMTP éventuelle. */
  const envoyer = async (to: string, lien: string) => {
    await transport.sendMail({
      from, to, subject: SUJET,
      html: htmlInvitation(lien),
      text: texteInvitation(lien),
    });
  };

  try {
    // --- Mode TEST : une seule invitation à l'adresse fournie, rien n'est modifié.
    if (testEmail) {
      const r = rows[0] as EnvoiRow;
      const lien = lienPersonnalise(formUrl, r);
      try {
        await envoyer(testEmail, lien);
      } catch (e) {
        const detail = e instanceof Error ? e.message : String(e);
        return json({ ok: false, test: true, to: testEmail, error: `Brevo (SMTP) a refusé l'envoi : ${detail}` }, 502);
      }
      return json({ ok: true, test: true, to: testEmail, lien, transport: `${smtpHost}:${smtpPort}` });
    }

    // --- Envoi réel, ligne par ligne, puis passage à 'envoye'.
    let envoyes = 0;
    const erreurs: Array<{ id: string; email: string | null; erreur: unknown }> = [];
    for (const row of rows as EnvoiRow[]) {
      const lien = lienPersonnalise(formUrl, row);
      try {
        await envoyer(row.email!, lien);
      } catch (e) {
        erreurs.push({ id: row.id, email: row.email, erreur: e instanceof Error ? e.message : String(e) });
        continue;
      }
      const { error: eUp } = await supabase
        .from("envois_sondage")
        .update({ statut_envoi: "envoye", date_envoi: now.toISOString() })
        .eq("id", row.id);
      if (eUp) { erreurs.push({ id: row.id, email: row.email, erreur: eUp.message }); continue; }
      envoyes++;
    }

    return json({ ok: erreurs.length === 0, campagne, envoyes, echecs: erreurs.length, erreurs: erreurs.slice(0, 20) });
  } finally {
    transport.close();
  }
});
