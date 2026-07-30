#!/usr/bin/env node
// =============================================================================
//  ANSET — Création en masse des comptes d'accès à l'app de pilotage.
//
//  Un compte par personne listée ci-dessous : MANAGERS (pilotage réseau complet)
//  et CONSEILLERS (périmètre limité à leurs propres réponses).
//
//  POURQUOI DEUX LISTES NOMINATIVES ET PAS « TOUS LES CONSEILLERS DE LA TABLE »,
//  comme dans la première version : `conseillers` contient aussi les PARTANTS, et
//  ce n'est pas un défaut. Les réponses d'un client restent comptées dans les
//  agrégats même si le conseiller qui l'a suivi a quitté ANSET — rien dans les vues
//  ne filtre sur `conseillers.actif`, et c'est voulu. La table est donc l'historique
//  des gestionnaires, pas l'organigramme du jour : partir d'elle recréerait les
//  comptes des partants (28 supprimés à dessein le 30/07/2026).
//
//  Pourquoi un script et pas l'onglet Utilisateurs : une cinquantaine de comptes
//  à créer un par un, chacun avec son rattachement. Le script fait exactement ce
//  que fait l'Edge Function `admin-utilisateurs` (créer l'utilisateur auth PUIS
//  la ligne `profils`), avec la même règle d'adresse `<login>@anset.pf`.
//
//  IDEMPOTENT : relançable. Un compte déjà présent est laissé tel quel (son mot
//  de passe n'est pas réinitialisé), seul un profil manquant est complété.
//
//  Usage :
//    export SUPABASE_SERVICE_ROLE_KEY="…"        # Supabase → Settings → API
//    node scripts/creer_comptes.mjs --dry        # aperçu, aucune écriture
//    node scripts/creer_comptes.mjs              # création réelle
//    node scripts/creer_comptes.mjs > comptes.txt   # garder les mots de passe
//
//  PRÉREQUIS : la migration 20260730100000_role_conseiller.sql doit être
//  appliquée (colonne `profils.conseiller_id` + rôle `conseiller` admis) —
//  le script le vérifie et s'arrête sinon.
//
//  ⚠ Les mots de passe provisoires ne s'affichent qu'une fois, ici. Ils sont
//  personnels et à usage unique : à transmettre puis à faire changer. Ne pas
//  committer la sortie.
// =============================================================================

const SB_URL = process.env.SUPABASE_URL ?? "https://xizitftoejfxaizztzeu.supabase.co";
const SERVICE = process.env.SUPABASE_SERVICE_ROLE_KEY;
const DRY = process.argv.includes("--dry");
const DOMAINE = "anset.pf";

// --- Qui est manager ---------------------------------------------------------
// Ces personnes voient le pilotage réseau entier, pas seulement leur périmètre.
// Le `login` sert à les reconnaître dans `conseillers` ET à composer l'adresse ;
// un manager qui ne figure pas dans la table est créé quand même (il n'a pas
// besoin de périmètre).
const MANAGERS = [
  { login: "vaiana.fromont",  nom: "Vaiana Fromont" },
  { login: "joeffray.michel", nom: "Joeffray Michel" },
  { login: "maimiti.tapare",  nom: "Maimiti Tapare" },
];

// --- Les conseillers actifs --------------------------------------------------
// Liste fournie par le métier le 30/07/2026. À TENIR À JOUR : c'est elle qui fait
// foi, pas la table `conseillers` (cf. l'en-tête). Une arrivée s'ajoute ici, un
// départ se retire ici puis se désactive dans l'onglet Utilisateurs — sans jamais
// toucher à ses données, qui continuent d'alimenter les indicateurs.
//
// Une chaîne = l'adresse ET le rattachement sont identiques, le cas courant.
// Un objet = les deux DIVERGENT, et il faut alors savoir lequel sert à quoi :
//   · `adresse`       → la boîte réelle de la personne, avec laquelle elle se connecte ;
//   · `conseiller_id` → la clé produite par l'extraction mensuelle (`slugConseiller`
//                       remplace tout séparateur par un point), et donc la seule
//                       valeur qui porte ses envois et ses réponses.
// Un nom composé s'écrit « maiau-tetua » dans l'annuaire et « maiau.tetua » dans la
// requête : mettre le tiret dans le rattachement rattacherait la personne à un
// conseiller inexistant, et son écran resterait vide.
const CONSEILLERS = [
  "raina.amaru", "james.laudes", "dorian.bodin", "daisy.lysao", "tahiata.teissier",
  "eimeo.chanlo", "jeannine.cuny", "manutaia.tehahe", "oceane.paulin", "poetini.teahui",
  "miwana.hauata", "ioane.tuporo", "deana.tamarii", "angela.faraire", "kaureka.tehei",
  "melina.teraiamano", "mairani.ateo", "vaiani.teahui", "naea.raveino", "hina.sansine",
  "titaina.pea", "muriel.lima",
  { adresse: "heilani.maiau-tetua",   conseiller_id: "heilani.maiau.tetua" },
  { adresse: "titaina.raapoto-rehua", conseiller_id: "titaina.raapoto.rehua" },
];
// Maimiti Tapare figure dans la liste métier des conseillers actifs mais reste
// `manager` (arbitré le 30/07/2026) : elle pilote le réseau entier. Elle est donc
// dans MANAGERS et pas ici — un compte ne porte qu'un rôle.

// -----------------------------------------------------------------------------
if (!SERVICE) {
  console.error("✗ SUPABASE_SERVICE_ROLE_KEY manquante (Supabase → Settings → API → service_role).");
  process.exit(1);
}

const H = { apikey: SERVICE, Authorization: `Bearer ${SERVICE}`, "Content-Type": "application/json" };

async function api(path, init = {}) {
  const res = await fetch(`${SB_URL}${path}`, { ...init, headers: { ...H, ...(init.headers ?? {}) } });
  const txt = await res.text();
  let body = null;
  try { body = txt ? JSON.parse(txt) : null; } catch { body = txt; }
  return { ok: res.ok, status: res.status, body };
}

/** Même format que l'Edge Function : lisible à l'oral, sans I/l/0/O ambigus. */
function motDePasseProvisoire() {
  const alpha = "ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnpqrstuvwxyz23456789";
  const buf = new Uint32Array(16);
  crypto.getRandomValues(buf);
  const s = [...buf].map((n) => alpha[n % alpha.length]).join("");
  return `${s.slice(0, 4)}-${s.slice(4, 8)}-${s.slice(8, 12)}-${s.slice(12, 16)}`;
}

const titre = (slug) => slug.split(".").map((p) => (p ? p[0].toUpperCase() + p.slice(1) : "")).join(" ").trim();

/** Tous les utilisateurs auth, paginés : sert à ne jamais recréer un compte. */
async function utilisateursAuth() {
  const map = new Map();
  for (let page = 1; page <= 50; page++) {
    const { ok, body } = await api(`/auth/v1/admin/users?page=${page}&per_page=200`);
    if (!ok) throw new Error(`Lecture des comptes auth impossible : ${JSON.stringify(body)}`);
    const users = body?.users ?? [];
    users.forEach((u) => u.email && map.set(u.email.toLowerCase(), u.id));
    if (users.length < 200) break;
  }
  return map;
}

// -----------------------------------------------------------------------------
const main = async () => {
  // Garde-fou : sans la migration, l'insert du profil échouerait une ligne sur
  // deux et laisserait des utilisateurs auth orphelins.
  const sonde = await api("/rest/v1/profils?select=conseiller_id&limit=1");
  if (!sonde.ok) {
    console.error("✗ La migration 20260730100000_role_conseiller.sql n'est pas appliquée "
      + `(colonne profils.conseiller_id absente) — \`supabase db push\` d'abord.\n  ${JSON.stringify(sonde.body)}`);
    process.exit(1);
  }

  const [{ body: conseillers }, { body: profils }, authParEmail] = await Promise.all([
    api("/rest/v1/conseillers?select=id,nom&order=id"),
    api("/rest/v1/profils?select=user_id,email,role,conseiller_id"),
    utilisateursAuth(),
  ]);
  if (!Array.isArray(conseillers)) throw new Error(`Lecture de conseillers impossible : ${JSON.stringify(conseillers)}`);

  const profilParEmail = new Map((profils ?? []).map((p) => [String(p.email).toLowerCase(), p]));
  const nomParId = new Map(conseillers.map((c) => [c.id, c.nom]));

  // Une entrée-chaîne signifie « adresse et rattachement identiques ».
  const conseillersNormalises = CONSEILLERS.map((c) =>
    typeof c === "string" ? { adresse: c, conseiller_id: c } : c);

  // Un rattachement absent de `conseillers` violerait la clé étrangère de
  // `profils` : l'erreur arriverait compte par compte, au milieu de la boucle. On
  // s'arrête avant d'avoir rien créé — une faute de frappe dans la liste ci-dessus
  // est le scénario le plus probable, et elle laisserait sinon la personne
  // rattachée à un conseiller inexistant, écran vide et cause invisible.
  const inconnus = conseillersNormalises.filter((c) => !nomParId.has(c.conseiller_id));
  if (inconnus.length) {
    console.error("✗ Rattachement inconnu dans la table `conseillers` :\n"
      + inconnus.map((c) => `    ${c.conseiller_id}  (adresse ${c.adresse}@${DOMAINE})`).join("\n")
      + "\n  Vérifie l'orthographe : la clé est celle de la colonne « Gestionnaire »"
      + " de la requête mensuelle, séparateurs remplacés par des points.");
    process.exit(1);
  }

  const aCreer = [
    ...MANAGERS.map((m) => ({ login: m.login, nom: m.nom, role: "manager", conseiller_id: null })),
    ...conseillersNormalises.map((c) => ({
      login: c.adresse,
      nom: nomParId.get(c.conseiller_id) || titre(c.conseiller_id),
      role: "conseiller",
      conseiller_id: c.conseiller_id,
    })),
  ];

  console.log(`${DRY ? "APERÇU — aucune écriture" : "CRÉATION"} · ${aCreer.length} compte(s) · ${SB_URL}\n`);
  const lignes = [];

  for (const c of aCreer) {
    const email = `${c.login}@${DOMAINE}`;
    const existant = profilParEmail.get(email);
    if (existant) { lignes.push([email, existant.role, existant.conseiller_id ?? "—", "déjà en place"]); continue; }
    if (DRY) { lignes.push([email, c.role, c.conseiller_id ?? "—", "à créer"]); continue; }

    // Réutiliser un utilisateur auth existant sans profil (reprise après échec) :
    // le recréer renverrait « already registered » et bloquerait la boucle.
    let userId = authParEmail.get(email), motdepasse = null;
    if (!userId) {
      motdepasse = motDePasseProvisoire();
      const r = await api("/auth/v1/admin/users", {
        method: "POST",
        body: JSON.stringify({ email, password: motdepasse, email_confirm: true }),
      });
      if (!r.ok || !r.body?.id) { lignes.push([email, c.role, c.conseiller_id ?? "—", `✗ ${r.body?.msg ?? r.body?.error_description ?? r.status}`]); continue; }
      userId = r.body.id;
    }

    const p = await api("/rest/v1/profils", {
      method: "POST",
      headers: { Prefer: "return=minimal" },
      body: JSON.stringify({ user_id: userId, email, nom: c.nom, role: c.role, conseiller_id: c.conseiller_id }),
    });
    if (!p.ok) {
      // Profil manquant = compte inutilisable : on annule, comme le fait
      // l'Edge Function, plutôt que de laisser un utilisateur auth orphelin.
      if (motdepasse) await api(`/auth/v1/admin/users/${userId}`, { method: "DELETE" });
      lignes.push([email, c.role, c.conseiller_id ?? "—", `✗ profil refusé : ${p.body?.message ?? p.status}`]);
      continue;
    }
    lignes.push([email, c.role, c.conseiller_id ?? "—", motdepasse ?? "compte auth préexistant (mot de passe inchangé)"]);
  }

  const l = (i) => Math.max(...lignes.map((x) => String(x[i]).length));
  const [w0, w1, w2] = [l(0), l(1), l(2)];
  console.log(`${"E-MAIL".padEnd(w0)}  ${"RÔLE".padEnd(w1)}  ${"PÉRIMÈTRE".padEnd(w2)}  MOT DE PASSE PROVISOIRE`);
  lignes.forEach((x) => console.log(`${String(x[0]).padEnd(w0)}  ${String(x[1]).padEnd(w1)}  ${String(x[2]).padEnd(w2)}  ${x[3]}`));

  const crees = lignes.filter((x) => /^[A-Za-z0-9]{4}-/.test(String(x[3]))).length;
  const echecs = lignes.filter((x) => String(x[3]).startsWith("✗")).length;
  console.log(`\n${DRY ? "Aperçu terminé." : `${crees} compte(s) créé(s), ${echecs} échec(s).`}`
    + " Les conseillers se connectent avec leur seul identifiant, la page complète le domaine"
    + " (ex. hina.sansine, ou heilani.maiau-tetua : c'est l'ADRESSE qui se saisit, pas le périmètre).");
};

main().catch((e) => { console.error("✗", e.message); process.exit(1); });
