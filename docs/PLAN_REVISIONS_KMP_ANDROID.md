# nōto. — Plan d'exécution pour Claude Code

> À placer à la racine du repo `jtassy-stack/noto` (`docs/PLAN_REVISIONS_KMP_ANDROID.md`) et à donner à Claude Code phase par phase.
> Base : `master` @ `97e7090` (2.0.0, iOS SwiftUI + SwiftData, App Store `6761330869`).
> Rédigé le 15/10/2026.

---

## 0. Cadre — à lire avant chaque phase

### Objectif
Faire de nōto le « Duolingo de l'école » pour le **collège et le lycée (6e → Terminale)** :
- **App enfant** : quiz courts tirés des devoirs et du programme officiel, gamifiés, qui débloquent du temps d'écran bonus.
- **App parent** : suivi des révisions et accompagnement au réglage du temps d'écran.
- **Disponible sur iOS et Android.**
- **Les connecteurs écoles** (Pronote, Mon Lycée / ENT, ÉcoleDirecte, Skolengo, annuaire) **sortis en module open source Kotlin Multiplatform**, avec un **serveur MCP local** pour que la communauté les améliore.

### Hors périmètre
- Le primaire (CP → CM2) : pas de banque de questions, pas de parcours, connecteurs primaire non prioritaires.
- Toute version hébergée du serveur MCP.
- Toute synchronisation par un serveur tiers avant la phase 9.

### Règles non négociables (complètent `CLAUDE.md`)
1. **Confidentialité** : aucun identifiant ne transite par un serveur ni n'y est stocké. Keychain sur iOS, EncryptedSharedPreferences / Keystore sur Android, trousseau système pour le MCP.
2. **Tests GET-only** sur les APIs réelles. Tout POST est mocké.
3. **Ton** : parent dans `DeviceMode.parent` (« Votre enfant… »). **Tutoiement autorisé uniquement en mode enfant** — mettre à jour `CLAUDE.md` en phase 1.
4. **Le verrou pendant les cours (`ClassScheduleShieldService`) n'est jamais levé par un crédit gagné.**
5. **Ne pas casser l'app iOS 2.0 en production** : chaque phase iOS garde le build vert et les tests existants verts.
6. Une branche et une pull request par phase. Commits atomiques en français ou en anglais, au choix, mais cohérents dans la PR.
7. Avant de coder une phase : lire les fichiers cités, proposer un plan court, puis exécuter.

### Prérequis environnement (sur le Mac)
- Xcode à jour + XcodeGen (`xcodegen generate`).
- JDK 17+, Android Studio (SDK 35, émulateur API 34+), Gradle wrapper.
- Accès réseau Maven Central, Google Maven, Gradle.
- `gh` authentifié sur `jtassy-stack`.

---

## Phase 1 — Hygiène et sécurité (½ journée)

**Branche** : `chore/security-hygiene`

### Constats de l'audit (15/10/2026)
- **Fuite** : clé de l'API annuaire en dur dans `Noto/Services/Directory/DirectoryAPIClient.swift:14` (`noto_32dd…`), publique depuis le commit du 16/04/2026.
- `node_modules/` du prototype React Native commité dans l'historique (faux positifs de secrets, repo très lourd).
- Aucun fichier `LICENSE`.

### Tâches
1. **Action manuelle Julien** : révoquer la clé côté serveur de l'annuaire et en générer une nouvelle.
2. Sortir la clé du code : lecture depuis `Info.plist` alimenté par une variable de build (`Config.xcconfig` non commité + secret GitHub Actions dans `.github/workflows/testflight.yml`). Fournir `Config.example.xcconfig`.
3. Ajouter `gitleaks` (ou équivalent) en hook pre-commit et dans la CI.
4. Mettre à jour `CLAUDE.md` : exception de tutoiement en mode enfant ; périmètre collège-lycée ; règle « crédit ≠ verrou cours ».
5. Ne **pas** réécrire l'historique du repo `noto` (trop risqué pour l'app en prod) : le repo open source sera neuf (phase 4).

### Critères d'acceptation
- `grep -r "noto_32dd" .` ne renvoie rien ; l'app iOS compile et récupère l'annuaire avec la nouvelle clé.
- La CI échoue si un secret est commité.

---

## Phase 2 — Programme officiel collège-lycée (1–2 jours)

**Branche** : `feat/curriculum-college-lycee`

### Constat
`Noto/Resources/curriculum.json` couvre correctement le collège (6e–3e : 6 à 8 matières, 17 à 23 thèmes) mais le lycée est quasi vide : **2nde = Français + Histoire seulement, ni 1re ni Terminale**.

### Tâches
1. Retirer CP → CM2 du parcours révisions (les garder dans le fichier si l'onglet Découvrir en dépend — vérifier `DiscoverView`, `ENTSyncService`, `Child.swift`).
2. Compléter **2nde** : maths, physique-chimie, SVT, SES, histoire-géographie, EMC, SNT, LV1/LV2, français.
3. Ajouter **1re et Terminale** : tronc commun (français en 1re, philosophie en Tle, histoire-géo, EMC, LV, enseignement scientifique, EPS) + spécialités (maths, PC, SVT, SES, HGGSP, HLP, LLCER, NSI, SI…). Ajouter un champ `track` (`tronc_commun` / `specialite`) et `specialty` optionnel.
4. Sources : programmes officiels publiés sur eduscol.education.fr / BO. Chaque thème garde `theme`, `keywords`, `period`.
5. Étendre `CurriculumService` : niveaux `1re`, `Tle`, filtre par spécialités de l'enfant (nouveau champ `Child.specialties: [String]`, migration SwiftData).
6. Mettre à jour `GradeInference` pour reconnaître 1re/Tle et les libellés Pronote (« PREMIERE », « TERMINALE », « 1G », « TG »…).

### Critères d'acceptation
- Test unitaire : chaque niveau 6e → Tle a au moins 6 matières et 3 thèmes par matière (hors spécialités).
- `CurriculumMatcher` retrouve un thème pour 10 libellés de devoirs réels anonymisés par niveau (fixtures).

---

## Phase 3 — Module Révisions sur iOS (sprint R1–R4, ~3 semaines)

**Branche** : `feat/revisions-ios` (sous-PR par sous-phase)

### 3.1 Modèles et logique pure
Fichiers à créer :
```
Noto/Models/QuizItem.swift         // @Model : id, prompt, kind (mcq/short/order), choices, answer, explanation, notion, level, subject, source (bank/homework/culture), sourceRef
Noto/Models/QuizAttempt.swift      // @Model : date, child, items, score, durationSec, minutesEarned
Noto/Models/NotionMastery.swift    // @Model : child, notion, leitnerBox (1–5), nextReview, streakCorrect
Noto/Models/NotoSchemaV2.swift     // migration depuis NotoSchemaV1
Noto/Services/Quiz/RewardPolicy.swift       // pur
Noto/Services/Quiz/SpacedRepetition.swift   // pur, Leitner 5 boîtes (1j, 2j, 4j, 8j, 16j)
Noto/Services/Quiz/QuizSourceSelector.swift // pur : devoirs à échéance ≤ 72 h (demain d'abord) + notions dues + programme
```
`RewardPolicy` (paramétrable par le parent) :
- barème par défaut : 1er quiz réussi 10 min, 2e 5 min, 3e 5 min, ensuite 0 ;
- seuil de réussite 4/5 ; plafond quotidien (défaut 20 min) ;
- bonus veille de contrôle (+5 min) si un devoir de demain contient « contrôle », « évaluation », « DS », « interro », « bac blanc » ;
- pas de minutes pour un quiz rejoué à l'identique ; pas de minutes si durée totale < 30 s.

Tests : 100 % des branches de `RewardPolicy`, `SpacedRepetition`, `QuizSourceSelector`.

### 3.2 Banque de questions
- `Noto/Resources/questions/<niveau>/<matiere>.json`, versionnée (`version`, `lastUpdated`), même logique de mise à jour distante que `curriculum.json` (TODO `checkForUpdate` à implémenter avec vérification de signature/hash).
- **Lot initial** : 6e et 2nde (niveaux réels de la famille), 4 matières chacun (français, maths, histoire-géo, SVT/physique-chimie), ≥ 15 questions par thème.
- Génération assistée possible hors app (script `tools/generate-questions/` avec Claude API, exécuté par Julien), **chaque question relue** avant commit ; champ `reviewed: true` obligatoire pour être servie.
- Le JSON référence les `theme` exacts de `curriculum.json` (test de cohérence).

### 3.2 bis S'appuyer sur celyn (quiz et recommandations) — décision du 15/10/2026
celyn (`jtassy-stack/culture-api`) fait déjà tourner un moteur de quiz en production (« Koi ? » pour Keskonfé, Sirius, Le Club) et un moteur de recommandation d'œuvres. On le réutilise au lieu de réinventer :
- **Pipeline de génération** : reprendre l'architecture de `src/lib/koi/` — une source par typologie (`QuizSource`, build `llm` | `deterministic`), questions **ancrées uniquement sur des faits stockés** (`groundingProblems`), **relecture à l'aveugle** (Jev via TypeSafe, repli Mistral) avec seuils de confiance, `question_key` pour dédoublonner, placement de la bonne réponse à une position tirée, signalement d'erreur (`report`) avec seuil d'exclusion et période de probation. Pour nōto : une typologie « programme » ancrée sur `curriculum.json` + les œuvres au programme, et une typologie déterministe (dates, œuvres/auteurs, prix littéraires) sans LLM.
- **Où générer** : de préférence côté celyn (job + table `koi_quizzes`, `app=noto`, contrat `quiz v2` — `GET /api/quiz/v2/lot`), la banque étant **non personnelle** : l'app ne télécharge que des questions, rien sur l'enfant ne remonte. À défaut, `tools/generate-questions/` réutilise le même pipeline hors ligne. Le champ `reviewed: true` de 3.2 correspond à `review_method`/`review_confidence` de celyn.
- **Question du jour culture G (3.6)** : servie par le lot quotidien Koi (`/api/partie/daily` ou `quiz v2`), filtrée par niveau, au lieu d'une banque dédiée.
- **Recommandations de livres, films, etc.** : catalogue `oeuvres` de celyn (type `book`, prix `oeuvre_awards`, `?awarded=true`), `/api/recommendations/:oeuvreId`, et recherche thématique par niveau (`?grade=`). Relier les œuvres au programme (`curriculum.json`, ex. « Les Fourberies de Scapin » en 5e) aux œuvres celyn pour proposer « à lire / à voir » après un quiz ou un devoir.
- **Avant de coder** : charger le skill `/celyn` (règle CLAUDE.md) et lire `docs/quiz-v2-contrat.md` de celyn ; ne jamais envoyer de données de l'enfant (requêtes anonymisées : niveau + thème).

### 3.3 Génération personnalisée (iOS 26)
- `Noto/Services/Quiz/QuizGenerator.swift` : chaîne **FoundationModels → banque**.
- Activer le code FoundationModels aujourd'hui commenté (`TextSummarizer`, `BriefingTools`, `MeetingExtractionService`) derrière `if #available(iOS 26, *)`.
- Guided generation (`@Generable`) sur une struct `GeneratedQuiz` ; prompt ancré sur le texte du devoir uniquement, en tutoiement ; rejet si une réponse n'apparaît pas dans le texte source ou la banque.
- Fallback silencieux sur la banque. **Aucun appel réseau** pour générer.

### 3.4 Mécanisme de récompense (ScreenTime)
```
Shared/RewardLedger.swift                       // solde, crédits du jour, plafond — app group, enveloppe versionnée comme ScreenTimeEventStore
Noto/Services/ScreenTime/RewardUnlockService.swift
NotoDeviceActivity/DeviceActivityMonitorExtension.swift  // + branche "noto.reward."
```
Flux :
1. Quiz réussi → `RewardLedger.credit(minutes)`.
2. `RewardUnlockService.unlock()` : lève le shield de l'`appLimitStore` (store par défaut) puis enregistre `DeviceActivityName("noto.reward.<uuid>")` sur la sélection persistée (`ScreenTimeEventStore.loadWatchedSelection()`), intervalle = maintenant → 23:59, `DeviceActivityEvent` seuil = minutes créditées.
3. Extension : `eventDidReachThreshold` sur `noto.reward.*` → réapplique le shield de la sélection, journalise, décrémente le ledger.
4. `intervalDidStart` minuit : stoppe les activités `noto.reward.*` de la veille (stocker leurs noms dans le ledger) ; reset.
5. Nettoyage défensif au foreground (comme `clearIfOutsideClassHours`).
6. **Garde** : si l'heure courante est dans un bloc de `ClassScheduleShieldService`, le crédit est mis en réserve, pas consommé.
7. Limite de 20 activités `DeviceActivityCenter` : au plus 3 activités reward simultanées ; fusionner sinon.

Test manuel documenté (`docs/TEST_REWARD.md`) sur appareil réel : budget épuisé → quiz → apps débloquées N min → rebloquées.

### 3.5 App enfant
Remplacer `Noto/Views/ChildHomeView.swift` par `Noto/Views/Child/` :
- `ChildHomeView` : cagnotte (« Ta cagnotte : 12 min »), série, bouton « Réviser (3 min) », EDT du jour (existant), statut contrôle.
- `QuizView` (une question par écran, chronomètre discret, feedback immédiat + explication), `QuizResultView` (minutes gagnées, XP).
- `SubjectPathView` : thèmes du niveau, progression par thème.
- Garder l'accès Réglages derrière `ParentGateView`.

### 3.6 Gamification
- XP par question, niveau par matière, série quotidienne + 2 jokers/mois, badges sur jalons réels (thème maîtrisé = toutes les notions en boîte ≥ 4).
- Question du jour de culture générale : lot quotidien Koi de celyn (voir 3.2 bis), requête anonymisée (niveau + thème, pas de lat/lng).
- Défi familial hebdo : désactivé par défaut, activable par le parent.

### 3.7 App parent
- `ScreenTimeView` : onboarding guidé (profil d'âge 11–13 / 14–15 / 16–18 avec repères, apps loisirs, apps toujours permises, budget de base, plafond gagnable, barème, plages nuit/repas).
- Écran **Révisions** : quiz faits, notions maîtrisées / fragiles, minutes gagnées vs utilisées, série — V1 lisible sur l'appareil de l'enfant derrière le PIN.
- `BriefingEngine` : item « Révisions » au ton parent.
- Bilan hebdo (notification locale dimanche soir) avec suggestion d'ajustement.

### Critères d'acceptation phase 3
- Build iOS vert, tests existants + nouveaux verts.
- Parcours complet sur iPhone réel en mode enfant : quiz 6e et 2nde, minutes créditées, apps débloquées puis rebloquées, verrou cours intact.
- `PrivacyInfo.xcprivacy` à jour (aucun nouveau flux réseau en V1).
- TestFlight via `asc-kit` (`/asc-ship`).

---

## Phase 4 — Socle Kotlin Multiplatform open source `noto-school-kit` (~3 semaines)

**Nouveau repo** : `jtassy-stack/noto-school-kit` (privé jusqu'à la phase 6, puis public). Licence : **GPL-3.0** recommandée (compatible avec Pawnote si on l'utilise en référence ; à confirmer par un avis juridique) — décision à valider par Julien avant passage public.

### Structure
```
noto-school-kit/
  core/            // modèles communs : Child, Homework, Grade, ScheduleEntry, Message, Absence, School ; interfaces CredentialStore, HttpEngine
  directory/       // portage de Noto/Services/Directory (ENTRegistry, GeoCommuneResolver, DirectoryAPIClient) — clé injectée, jamais en dur
  skolengo/        // portage de SkolengoClient + SkolengoTypes
  pronote/         // portage de l'implémentation NATIVE (PronoteClient, PronoteCrypto, PronoteAuth, PronoteTypes) — pas de Pawnote
  ent/             // ENTClient, ENTTypes, AbsenceService, MonLycée ; auth web en module plateforme
  ecoledirecte/    // EcoleDirecteClient (séparé de la sync SwiftData), types
  revisions/       // logique pure partagée : RewardPolicy, SpacedRepetition, QuizSourceSelector, formats banque/curriculum
  conformance/     // fixtures anonymisées + tests rejoués hors ligne par connecteur
  mcp-server/      // phase 5
```
- Cibles : `jvm`, `androidTarget`, `iosArm64`, `iosSimulatorArm64`.
- Réseau : Ktor client ; sérialisation : kotlinx.serialization ; crypto Pronote : implémentation multiplateforme (vérifier AES/RSA dispo, sinon `expect/actual`).
- Auth par navigateur caché (certains ENT, `HeadlessENTAuth`) : `expect/actual` — WebKit iOS, WebView Android, non supporté JVM.

### Ordre
1. `core` + `directory` + `skolengo` (petits, valident la forme).
2. `revisions` (porter depuis la phase 3.1, mêmes tests).
3. `pronote` natif — **vérifier d'abord que `PronoteClient` natif couvre login QR, refresh token, devoirs, notes, EDT, messages** ; lister les trous avant portage.
4. `ent` / Mon Lycée, puis `ecoledirecte`.

### Critères d'acceptation
- `./gradlew check` vert sur les 4 cibles.
- Tests de conformité : chaque connecteur rejoue ses fixtures et produit les modèles `core` attendus.
- Aucun appel POST dans les tests ; aucun secret dans le repo (gitleaks en CI).

---

## Phase 5 — Serveur MCP local `noto-school-mcp` (~1 semaine)

Dans `noto-school-kit/mcp-server/`, avec le SDK MCP Kotlin officiel, transport **stdio uniquement**.

### Outils (lecture seule)
`find_school`, `list_children`, `get_homework(child, from, to)`, `get_grades(child, period)`, `get_schedule(child, date)`, `get_messages(child, limit)`, `get_absences(child)`, `connection_healthcheck(child)`.

### Exigences
- Identifiants dans le trousseau système (macOS Keychain via `security`, libsecret sous Linux) ; commande `noto-school-mcp login <provider>` interactive en local.
- Fichier de config pour restreindre le périmètre (ex. désactiver `get_messages`).
- README : usage personnel avec ses propres identifiants, données transmises au modèle choisi par l'utilisateur, aucune version hébergée.
- Distribution : JAR + script d'installation ; exemple de config Claude Desktop / Claude Code.

### Critères d'acceptation
- Testé avec Claude Desktop sur un compte réel (lecture seule).
- `connection_healthcheck` réutilise la logique de `ConnectionHealthcheckService`.

---

## Phase 6 — Ouverture open source (2–3 jours)

1. **Avis juridique** (Pronote / Index Éducation, ENT, ÉcoleDirecte) avant passage public.
2. README, `CONTRIBUTING.md` (« ajouter / corriger un connecteur » : fixtures anonymisées obligatoires), `SECURITY.md`, `CODE_OF_CONDUCT.md`, templates d'issues « connecteur cassé ».
3. CI publique : build, tests de conformité, gitleaks.
4. Publication Maven Central (ou GitHub Packages) des artefacts.
5. Passage du repo en public, annonce (communautés Papillon / Pawnote).

---

## Phase 7 — App Android (~4–5 semaines)

**Dossier** : `android/` dans le repo `noto` (monorepo) ou repo `noto-android` — à trancher en début de phase.

### 7.1 Squelette
- Kotlin, Jetpack Compose, Hilt, Room (équivalent SwiftData), DataStore, Coroutines.
- Dépend de `noto-school-kit` (connecteurs + revisions).
- Utiliser le plugin `port-to-android` (`/port-to-android-init` puis `/port-to-android --bootstrap`) pour porter les vues SwiftUI et le thème `NotoTheme`.

### 7.2 Prototype de blocage — **à faire en premier, c'est le risque principal**
- `UsageStatsManager` (permission `PACKAGE_USAGE_STATS`) pour mesurer le temps par app.
- `AccessibilityService` détectant l'app au premier plan + écran de blocage par-dessus ; alternative à comparer : mode Device Owner (plus robuste, installation lourde).
- Même logique `RewardPolicy` / ledger que iOS, partagée via `revisions`.
- Verrou pendant les cours depuis l'EDT synchronisé ; jamais levé par un crédit.
- Protection contre la désinstallation / désactivation : Device Admin + code parent.
- **Conformité Google Play** : déclaration d'usage de l'API d'accessibilité pour contrôle parental, Families Policy, Data safety. Rédiger les justificatifs dans `android/docs/PLAY_COMPLIANCE.md`.
- Critère : sur émulateur et appareil réel, budget épuisé → app bloquée → quiz → débloquée N min → rebloquée.

### 7.3 Parité fonctionnelle
Mode parent / mode enfant (`DeviceMode`), onboarding (choix d'établissement via `directory`, connexion Pronote QR / ENT / ÉcoleDirecte / Skolengo), accueil briefing, école (notes, EDT, devoirs, messages), révisions, gamification, réglages temps d'écran, code parent.

### 7.4 Livraison
- Build signé, piste de test interne Google Play.

---

## Phase 8 — Bascule iOS sur le socle partagé (progressive)

- Intégrer `noto-school-kit` dans iOS via framework KMP (SPM binaire ou XCFramework), **connecteur par connecteur**, derrière un flag local.
- Ordre : annuaire → Skolengo → revisions → Pronote natif (retrait de `pawnote-bundle.js` et de `PawnoteBridge` une fois la parité atteinte, ce qui lève la contrainte GPL dans l'app) → ENT → ÉcoleDirecte.
- Pour chaque bascule : tests de non-régression sur comptes réels en lecture seule, puis TestFlight.

---

## Phase 9 — Synchronisation parent ↔ enfant (V2)

- iOS : CloudKit, zone partagée (CKShare) familiale, **uniquement les résultats** (attempts, mastery, minutes, série).
- Android et mixte iOS/Android : à concevoir — CloudKit ne couvre pas Android. Options à évaluer : sync chiffrée de bout en bout via un relais sans connaissance du contenu, ou appairage local (QR + réseau local). Décision à documenter avant tout code.
- Notifications locales côté parent.

---

## Suivi

| Phase | Dépend de | Livrable | Statut |
|---|---|---|---|
| 1 Hygiène | — | clé retirée, CI secrets, CLAUDE.md | à faire |
| 2 Programme | 1 | curriculum 6e → Tle | à faire |
| 3 Révisions iOS | 2 | quiz + récompense + enfant/parent sur TestFlight | à faire |
| 4 KMP kit | 1 | noto-school-kit (privé) | à faire |
| 5 MCP | 4 | serveur MCP local | à faire |
| 6 Open source | 4, 5, avis juridique | repo public | à faire |
| 7 Android | 4 (+3 pour la logique) | app Android, piste interne | à faire |
| 8 Bascule iOS | 4 | iOS sur le socle | à faire |
| 9 Sync | 3, 7 | sync familiale | à faire |

Parallélisable : phases 3 et 4 en même temps (deux sessions Claude Code, deux branches) ; le prototype de blocage Android (7.2) peut démarrer dès la phase 4 lancée.

## Décisions encore ouvertes (à trancher par Julien)
1. Licence finale du kit (GPL-3.0 recommandée) — après avis juridique.
2. Android : monorepo `noto/android` ou repo séparé.
3. Android : blocage par accessibilité ou par Device Owner.
4. Sync mixte iOS/Android (phase 9).
5. Usage optionnel de Claude API pour générer des questions côté app (désactivé en V1).

---

## Prompt de démarrage à coller dans Claude Code

```
Lis docs/PLAN_REVISIONS_KMP_ANDROID.md et CLAUDE.md.
On démarre la Phase 1. Lis les fichiers cités, propose un plan court,
puis exécute sur la branche chore/security-hygiene et ouvre une PR.
Respecte les règles non négociables de la section 0.
```
