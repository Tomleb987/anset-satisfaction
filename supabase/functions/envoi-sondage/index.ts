// =============================================================================
// ANSET — Edge Function `envoi-sondage`  (verify_jwt=true : manager/service)
// -----------------------------------------------------------------------------
// Envoie les invitations au sondage via Brevo, à partir de la table
// `envois_sondage` (lignes statut_envoi='a_envoyer' de la campagne du mois).
// Chaque invitation porte un LIEN PERSONNALISÉ (agence, conseiller, req) →
// réponse rattachée + lead pré-attribué. Programmé "à chaud" à H+2 (scheduledAt).
//
// Idempotent : une ligne passée à 'envoye' n'est jamais renvoyée.
//
// Modes (query string) :
//   (défaut)          envoie le lot 'a_envoyer' de la campagne courante
//   ?campagne=YYYY-MM cible une campagne précise
//   ?limit=N          plafonne le lot (défaut 500)
//   ?dry=1            simule : ne contacte pas Brevo, ne modifie rien
//   ?test=a@b.pf      TEST : envoie 1 invitation à cette adresse, tout de suite
//                     (pas de programmation H+2), ne modifie rien
//
// Secrets/env : BREVO_API_KEY, BREVO_TEMPLATE_ID, FORM_URL,
//               BREVO_SENDER_EMAIL, BREVO_SENDER_NAME (optionnels si gérés au template),
//               SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY (auto).
// Env optionnel : ALLOWED_ORIGIN (restreindre le CORS ; défaut "*").
// =============================================================================

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

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

/** Appel API Brevo (transactional email). Retourne {ok, info}. */
async function envoyerBrevo(
  apiKey: string,
  templateId: number,
  to: { email: string; name?: string },
  params: Record<string, unknown>,
  scheduledAt: string | null,
  sender: { email?: string; name?: string },
): Promise<{ ok: boolean; info: unknown }> {
  const body: Record<string, unknown> = { to: [to], templateId, params };
  if (scheduledAt) body.scheduledAt = scheduledAt;
  if (sender.email) body.sender = { email: sender.email, name: sender.name };
  const res = await fetch("https://api.brevo.com/v3/smtp/email", {
    method: "POST",
    headers: { "api-key": apiKey, "Content-Type": "application/json", Accept: "application/json" },
    body: JSON.stringify(body),
  });
  const info = await res.json().catch(() => ({}));
  return { ok: res.ok, info };
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
  // invisible dans l'UI et fait répondre « Key not found » à Brevo.
  const apiKey = Deno.env.get("BREVO_API_KEY")?.trim();
  const templateId = parseInt(Deno.env.get("BREVO_TEMPLATE_ID")?.trim() ?? "0", 10);
  const formUrl = Deno.env.get("FORM_URL")?.trim();
  const sender = {
    email: Deno.env.get("BREVO_SENDER_EMAIL")?.trim() || undefined,
    name: Deno.env.get("BREVO_SENDER_NAME")?.trim() || undefined,
  };

  if (!supabaseUrl || !serviceRole) return json({ ok: false, error: "Config Supabase incomplète." }, 500);
  if (!formUrl) return json({ ok: false, error: "FORM_URL manquant." }, 500);
  if (!dry && (!apiKey || !templateId)) return json({ ok: false, error: "BREVO_API_KEY ou BREVO_TEMPLATE_ID manquant." }, 500);

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

  // H+2 (envoi à chaud programmé).
  const scheduledAt = new Date(now.getTime() + 2 * 60 * 60 * 1000).toISOString();

  // --- Mode TEST : une seule invitation à l'adresse fournie, rien n'est modifié.
  if (testEmail) {
    const r = rows[0] as EnvoiRow;
    const lien = lienPersonnalise(formUrl, r);
    if (dry) return json({ ok: true, test: true, dry: true, to: testEmail, lien, prenom: r.prenom });
    // Envoi IMMÉDIAT (pas de scheduledAt) : un test programmé à H+2 n'arriverait que 2 h plus tard.
    const { ok, info } = await envoyerBrevo(apiKey!, templateId, { email: testEmail, name: r.prenom ?? "" }, { lien, prenom: r.prenom ?? "" }, null, sender);
    if (!ok) {
      const detail = (info as { message?: string; code?: string })?.message ?? JSON.stringify(info);
      return json({ ok: false, test: true, to: testEmail, error: `Brevo a refusé l'envoi : ${detail}`, brevo: info }, 502);
    }
    return json({ ok, test: true, to: testEmail, lien, brevo: info });
  }

  // --- Mode DRY : aperçu du lot sans envoi ni modification.
  if (dry) {
    return json({
      ok: true, dry: true, campagne, aTraiter: rows.length,
      apercu: (rows as EnvoiRow[]).slice(0, 5).map((r) => ({ email: r.email, prenom: r.prenom, lien: lienPersonnalise(formUrl, r) })),
    });
  }

  // --- Envoi réel, ligne par ligne, puis passage à 'envoye'.
  let envoyes = 0;
  const erreurs: Array<{ id: string; email: string | null; erreur: unknown }> = [];
  for (const row of rows as EnvoiRow[]) {
    const lien = lienPersonnalise(formUrl, row);
    const { ok, info } = await envoyerBrevo(
      apiKey!, templateId,
      { email: row.email!, name: row.prenom ?? "" },
      { lien, prenom: row.prenom ?? "" },
      scheduledAt, sender,
    );
    if (!ok) { erreurs.push({ id: row.id, email: row.email, erreur: info }); continue; }
    const { error: eUp } = await supabase
      .from("envois_sondage")
      .update({ statut_envoi: "envoye", date_envoi: now.toISOString() })
      .eq("id", row.id);
    if (eUp) { erreurs.push({ id: row.id, email: row.email, erreur: eUp.message }); continue; }
    envoyes++;
  }

  return json({ ok: erreurs.length === 0, campagne, envoyes, echecs: erreurs.length, scheduledAt, erreurs: erreurs.slice(0, 20) });
});
