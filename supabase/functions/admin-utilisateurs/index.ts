// =============================================================================
// ANSET — Edge Function `admin-utilisateurs`  (réservée au super admin)
// -----------------------------------------------------------------------------
// Crée et gère les comptes d'accès à l'app de pilotage. Passe obligatoirement par
// une fonction serveur : créer un utilisateur exige l'API admin de Supabase, donc
// la clé service_role, qui ne doit JAMAIS descendre dans le navigateur.
//
// Contrôle d'accès en deux temps (cf. `envoi-sondage`, même piège) :
//   1. `verify_jwt=true` ne suffit pas — la passerelle accepte aussi la clé
//      publishable, publique par nature.
//   2. On identifie donc l'appelant (auth.getUser) puis on exige que son profil
//      soit `role='super_admin'` ET `actif`.
//
// Actions (POST JSON) :
//   {action:"liste"}                                  → tous les profils
//   {action:"creer", email, nom, role}                → crée le compte, renvoie
//                                                       un mot de passe provisoire
//   {action:"role", user_id, role}                    → change le rôle
//   {action:"actif", user_id, actif}                  → désactive / réactive
//   {action:"supprimer", user_id}                      → supprime le compte
//
// Garde-fous : on ne peut ni se rétrograder, ni se désactiver, ni se supprimer
// soi-même, ni retirer le dernier super admin (sinon plus personne ne gère les
// comptes). Un compte désactivé est banni côté auth : il ne peut plus se connecter.
//
// Env : SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY (auto), ALLOWED_ORIGIN (optionnel).
// =============================================================================

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const ALLOWED_ORIGIN = Deno.env.get("ALLOWED_ORIGIN") ?? "*";

const CORS = {
  "Access-Control-Allow-Origin": ALLOWED_ORIGIN,
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Access-Control-Allow-Headers": "authorization, apikey, content-type",
  "Access-Control-Max-Age": "86400",
};

const json = (obj: unknown, status = 200) =>
  new Response(JSON.stringify(obj, null, 2), { status, headers: { ...CORS, "Content-Type": "application/json" } });

const ROLES = ["super_admin", "manager"] as const;

/** Bannissement « à vie » : la durée maximale acceptée par l'API admin. */
const BAN_LONG = "876000h"; // ~100 ans

/**
 * Mot de passe provisoire lisible à l'oral (pas de I/l/0/O ambigus), transmis
 * par le super admin au nouvel utilisateur, qui le changera à sa première
 * connexion. Généré côté serveur : jamais deviné par le navigateur.
 */
function motDePasseProvisoire(): string {
  const alpha = "ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnpqrstuvwxyz23456789";
  const buf = new Uint32Array(16);
  crypto.getRandomValues(buf);
  const s = [...buf].map((n) => alpha[n % alpha.length]).join("");
  return `${s.slice(0, 4)}-${s.slice(4, 8)}-${s.slice(8, 12)}-${s.slice(12, 16)}`;
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return json({ ok: false, error: "Méthode non autorisée." }, 405);

  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const serviceRole = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!supabaseUrl || !serviceRole) return json({ ok: false, error: "Config Supabase incomplète." }, 500);

  const supabase = createClient(supabaseUrl, serviceRole, { auth: { persistSession: false } });

  // --- Qui appelle ?
  const bearer = (req.headers.get("Authorization") ?? "").replace(/^Bearer\s+/i, "").trim();
  const { data: auth, error: eAuth } = await supabase.auth.getUser(bearer);
  if (eAuth || !auth?.user) {
    return json({ ok: false, error: "Accès refusé : connecte-toi à l'app de pilotage." }, 401);
  }
  const moi = auth.user.id;

  // --- Est-il super admin ?
  const { data: monProfil, error: eProfil } = await supabase
    .from("profils").select("role, actif").eq("user_id", moi).maybeSingle();
  if (eProfil) return json({ ok: false, error: eProfil.message }, 500);
  if (!monProfil || monProfil.role !== "super_admin" || !monProfil.actif) {
    return json({ ok: false, error: "Réservé au super administrateur." }, 403);
  }

  let corps: Record<string, unknown>;
  try { corps = await req.json(); } catch { return json({ ok: false, error: "Corps JSON attendu." }, 400); }
  const action = String(corps.action ?? "");

  /** Nombre de super admins actifs — sert à ne jamais laisser le compte orphelin. */
  const superAdminsActifs = async () => {
    const { count } = await supabase.from("profils").select("user_id", { count: "exact", head: true })
      .eq("role", "super_admin").eq("actif", true);
    return count ?? 0;
  };

  const liste = async () => {
    const { data, error } = await supabase
      .from("profils").select("user_id, email, nom, role, actif, created_at")
      .order("role", { ascending: true }).order("email", { ascending: true });
    if (error) return json({ ok: false, error: error.message }, 500);
    return json({ ok: true, moi, utilisateurs: data });
  };

  switch (action) {
    case "liste":
      return await liste();

    case "creer": {
      const email = String(corps.email ?? "").trim().toLowerCase();
      const nom = String(corps.nom ?? "").trim() || null;
      const role = String(corps.role ?? "manager");
      if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(email)) return json({ ok: false, error: "Adresse e-mail invalide." }, 400);
      if (!ROLES.includes(role as typeof ROLES[number])) return json({ ok: false, error: "Rôle inconnu." }, 400);

      const motdepasse = motDePasseProvisoire();
      // email_confirm : pas d'e-mail de validation à envoyer, le compte est
      // utilisable immédiatement avec le mot de passe provisoire.
      const { data: cree, error: eCreate } = await supabase.auth.admin.createUser({
        email, password: motdepasse, email_confirm: true,
      });
      if (eCreate || !cree?.user) {
        const m = eCreate?.message ?? "création impossible";
        return json({ ok: false, error: /already|exists|registered/i.test(m) ? `Un compte existe déjà pour ${email}.` : m }, 400);
      }

      const { error: eIns } = await supabase.from("profils")
        .insert({ user_id: cree.user.id, email, nom, role });
      if (eIns) {
        // Profil manquant = compte inutilisable : on annule la création plutôt
        // que de laisser un utilisateur auth orphelin.
        await supabase.auth.admin.deleteUser(cree.user.id);
        return json({ ok: false, error: `Profil non créé (${eIns.message}) — compte annulé.` }, 500);
      }
      return json({ ok: true, cree: { user_id: cree.user.id, email, nom, role }, motdepasse });
    }

    case "role": {
      const user_id = String(corps.user_id ?? "");
      const role = String(corps.role ?? "");
      if (!ROLES.includes(role as typeof ROLES[number])) return json({ ok: false, error: "Rôle inconnu." }, 400);
      if (user_id === moi) return json({ ok: false, error: "Change ton propre rôle depuis un autre compte super admin." }, 400);
      if (role !== "super_admin" && await superAdminsActifs() <= 1) {
        const { data: cible } = await supabase.from("profils").select("role").eq("user_id", user_id).maybeSingle();
        if (cible?.role === "super_admin") return json({ ok: false, error: "Il doit rester au moins un super administrateur." }, 400);
      }
      const { error } = await supabase.from("profils").update({ role }).eq("user_id", user_id);
      if (error) return json({ ok: false, error: error.message }, 500);
      return await liste();
    }

    case "actif": {
      const user_id = String(corps.user_id ?? "");
      const actif = corps.actif !== false;
      if (user_id === moi) return json({ ok: false, error: "Impossible de se désactiver soi-même." }, 400);
      if (!actif && await superAdminsActifs() <= 1) {
        const { data: cible } = await supabase.from("profils").select("role").eq("user_id", user_id).maybeSingle();
        if (cible?.role === "super_admin") return json({ ok: false, error: "Il doit rester au moins un super administrateur actif." }, 400);
      }
      // Le bannissement côté auth est ce qui bloque réellement la connexion ;
      // `profils.actif` n'est que le reflet lisible de cet état.
      const { error: eBan } = await supabase.auth.admin.updateUserById(user_id, { ban_duration: actif ? "none" : BAN_LONG });
      if (eBan) return json({ ok: false, error: eBan.message }, 500);
      const { error } = await supabase.from("profils").update({ actif }).eq("user_id", user_id);
      if (error) return json({ ok: false, error: error.message }, 500);
      return await liste();
    }

    case "supprimer": {
      const user_id = String(corps.user_id ?? "");
      if (user_id === moi) return json({ ok: false, error: "Impossible de supprimer son propre compte." }, 400);
      const { data: cible } = await supabase.from("profils").select("role").eq("user_id", user_id).maybeSingle();
      if (cible?.role === "super_admin" && await superAdminsActifs() <= 1) {
        return json({ ok: false, error: "Il doit rester au moins un super administrateur." }, 400);
      }
      // La FK `on delete cascade` retire le profil avec l'utilisateur auth.
      const { error } = await supabase.auth.admin.deleteUser(user_id);
      if (error) return json({ ok: false, error: error.message }, 500);
      return await liste();
    }

    default:
      return json({ ok: false, error: `Action inconnue : « ${action} ».` }, 400);
  }
});
