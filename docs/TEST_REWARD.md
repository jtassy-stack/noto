# Test manuel — récompense Screen Time (phase 3.4)

DeviceActivity et ManagedSettings ne tournent **pas** dans le Simulateur : ce test se fait sur un **iPhone réel**, build Debug installé depuis Xcode (l'extension `NotoDeviceActivity` n'est embarquée que pour `iphoneos`, voir `project.yml`).

## Ce qui est testé

| # | Scénario | Résultat attendu |
|---|---|---|
| 1 | Budget épuisé → quiz réussi | Apps débloquées N min, puis rebloquées |
| 2 | Quiz pendant un cours | Crédit en réserve, apps toujours bloquées, libéré après le cours |
| 3 | Minuit | Activités `noto.reward.*` de la veille stoppées, crédits remis à zéro |
| 4 | 4 récompenses dans la journée | Au plus 3 activités, la plus ancienne fusionnée |
| 5 | Pas d'autorisation / pas de sélection | Aucun déblocage, aucun crash, libellé neutre |
| 6 | Désinstallation | Rien ne reste bloqué |
| 7 | Non-régression | Limite d'apps et verrou cours inchangés |

## Préparation

1. iPhone sous iOS 17.4+ (idéalement iOS 18/26), mode développeur activé, compte iCloud quelconque.
2. `xcodegen generate`, ouvrir `Noto.xcodeproj`, sélectionner l'iPhone, schéma `Noto`, Cmd+R.
3. Logs : **Console.app** → l'iPhone → filtre `noto` (processus `Noto` **et** `NotoDeviceActivity`). Les lignes utiles commencent par `[noto][reward]` (NSLog, app et extension) ou viennent de la catégorie `RewardUnlockService` (sous-système `com.pmf.noto`).
4. Dans nōto (mode parent) → Réglages → Temps d'écran :
   - autoriser Screen Time (`.individual`) ;
   - choisir 1 ou 2 apps « loisirs » faciles à ouvrir (ex. Calculatrice, Météo) ;
   - activer « Surveiller l'utilisation » avec le **plus petit budget** possible ;
   - lier l'appareil à l'enfant de test ;
   - régler le barème (Révisions) : `10 / 5 / 5`, plafond 20.
5. Passer l'appareil en mode enfant (onboarding ou réglage existant).

> Astuce budget : pour ne pas attendre 1 h, utilisez les apps surveillées jusqu'à ce que l'extension pose le bouclier. Log attendu dans l'extension : aucun `[noto][reward]`, mais l'événement « Temps d'écran total » apparaît côté parent.

## 1. Budget épuisé → quiz → débloqué N min → rebloqué

1. Vérifier que les apps surveillées affichent l'écran de blocage Screen Time.
2. Ouvrir nōto (mode enfant) → « Réviser (3 min) » → répondre juste à 5 questions, en plus de 30 s.
3. Écran de résultat : « +10 min dans ta cagnotte ».
4. Log attendu (app) :
   ```
   RewardUnlockService: Credited 10 min
   [noto][reward] unlocked noto.reward.<uuid> threshold 10 min (credit 10, merged 0)
   RewardUnlockService: Unlock: unlocked(...)
   ```
5. Revenir à l'accueil enfant : la carte sous la cagnotte dit **« Tes 10 min sont débloquées »**.
6. Ouvrir une app surveillée : elle s'ouvre (bouclier levé sur le store par défaut).
7. L'utiliser ~10 min (cumulé). Log attendu (extension) :
   ```
   [noto][reward] noto.reward.<uuid> used up — re-lock: yes
   ```
8. L'app affiche de nouveau l'écran de blocage. L'accueil enfant revient au libellé neutre.

**Échec typique** : si l'app ne se débloque pas, chercher `budgetNotSpent` (le bouclier n'était pas posé : budget pas encore épuisé, voir §1 bis) ou `noSelection` / `notAuthorized`.

### 1 bis. Quiz AVANT d'avoir épuisé le budget

1. Le matin (budget intact), faire un quiz réussi.
2. Accueil : **« Tes 10 min t'attendent »** + « Elles s'ajoutent quand ton temps d'écran du jour est fini. »
3. Log : `Unlock: budgetNotSpent` (rien n'est enregistré, le budget de base n'est pas entamé).
4. Épuiser le budget. Au moment où l'extension pose le bouclier, elle débloque aussitôt les minutes en attente :
   ```
   [noto][reward] unlocked noto.reward.<uuid> threshold 10 min ...
   [noto][reward] extension unlock: unlocked(...)
   ```
   Si ce rappel est manqué, l'ouverture suivante de nōto fait le déblocage (`foregroundRefresh`).

## 2. Quiz pendant un cours → réserve → libéré après le cours

Préparer un créneau de cours : un enfant avec un emploi du temps synchronisé contenant un cours **maintenant** (ou ajuster l'heure de l'iPhone pendant un cours de la semaine), verrou cours activé (Réglages → Temps d'écran → Verrouillage pendant les cours).

1. Commencer un quiz juste avant le début du bloc et le terminer (réussi) juste après : la garde regarde l'heure de fin du quiz, pas l'état du bouclier. Le verrou cours se pose après 1 min d'usage dans le bloc et peut masquer nōto ; c'est attendu.
2. Log attendu (app) :
   ```
   [noto][reward] in class: 10 min to reserve
   RewardUnlockService: Unlock: reserved(minutes: 10)
   ```
3. Accueil : **« Tes minutes t'attendent après les cours »**.
4. Vérifier que **toutes** les apps restent bloquées (le store `noto.classTimeLock` n'est jamais touché par la récompense, et le store par défaut n'est pas levé).
5. À la fin du bloc, log attendu (extension, best-effort) :
   ```
   [noto][reward] class block ended: 10 min released from reserve
   [noto][reward] extension unlock: unlocked(...)    // si le budget est épuisé
   ```
   Si `intervalDidEnd` est manqué (connu sur iOS récent), ouvrir nōto après le cours : `Released 10 min from reserve` puis `Unlock: unlocked(...)`.
6. Les apps surveillées se débloquent pour 10 min (si le budget est épuisé), sinon §1 bis.

## 3. Reset de minuit

1. Le soir, gagner des minutes et les laisser **non consommées** (« Tes N min sont débloquées »).
2. Laisser l'iPhone passer minuit (ou avancer l'heure à 23:58).
3. 23:59 — log extension : `noto.reward.<uuid> interval ended — re-lock: yes` (ou `no (budget not spent)` si le budget n'est plus épuisé). L'activité est arrêtée (`stopMonitoring`) dans les deux cas.
4. 00:00 — log extension :
   ```
   [noto][reward] midnight reset: stopped N reward activities
   ```
   (via `noto.screentime.daily` si la limite d'apps est active, sinon via `noto.reward.daily`). N compte les activités encore en cours à minuit : celles expirées à 23:59 sont déjà arrêtées, N peut donc valoir 0.
   Au foreground suivant, aucune activité `noto.reward.<uuid>` inconnue du registre ne doit rester enregistrée (log app `Stopped N unknown reward activities` si c'était le cas).
5. Le bouclier du budget est levé (nouveau jour), l'accueil revient au neutre, la cagnotte affiche 0 min.
6. Sans limite d'apps active : vérifier dans le log de l'app au foreground que `noto.reward.daily` est enregistré (pas d'erreur `noto.reward.daily not registered`).

## 4. Quatre récompenses → fusion

Barème temporaire : `5 / 5 / 5 / 5` (4 paliers), plafond 20, budget épuisé.

1. Faire 4 quiz réussis (questions différentes) à quelques minutes d'intervalle, sans utiliser les apps.
2. Logs attendus :
   ```
   ... threshold 5 min (credit 5, merged 0)
   ... threshold 10 min (credit 5, merged 0)
   ... threshold 15 min (credit 5, merged 0)
   ... threshold 20 min (credit 5, merged 1)   // la plus ancienne est stoppée
   ```
3. Il n'y a jamais plus de 3 `noto.reward.<uuid>` enregistrées en même temps.
4. Utiliser les apps : les activités plus anciennes atteignent leur seuil d'abord (`re-lock: no`), la dernière rebloque (`re-lock: yes`) après ~20 min d'usage cumulé depuis la **dernière** récompense.

5. Variante avec usage : quiz 1 (5 min), utiliser les apps ~3 min, puis quiz 2. Log extension `noto.reward.used.<n>` reçus, puis côté app `threshold 7 min (credit 5, ...)` environ (5 + ce qui reste de la première), pas `10 min`.

**Comportement attendu, pas un bug** : les activités récompense surveillent la même sélection en parallèle. Les seuils sont donc cumulatifs : nouvelle activité = son crédit + le plus grand **reste** encore en cours (seuil − usage déjà relevé par les jalons `noto.reward.used.<n>`). L'usage n'étant relevé qu'à chaque jalon (1 min, au plus 20 jalons par activité), l'enfant peut obtenir un peu plus que gagné (moins d'un pas de jalon par récompense empilée), jamais moins.

## 5. Sans autorisation ou sans sélection

1. Réglages → Temps d'écran : retirer toutes les apps surveillées (ou révoquer l'autorisation).
2. Faire un quiz réussi : « +10 min dans ta cagnotte », aucun crash.
3. Log : `Unlock: noSelection` (ou `notAuthorized`). Aucune activité enregistrée.
4. Accueil : libellé neutre « gagnées aujourd'hui », sans phrase « débloquées ».

## 6. Désinstallation

1. Avec une récompense en cours (apps débloquées) **et** un budget épuisé, supprimer nōto.
2. iOS retire les réglages ManagedSettings et les activités de l'app : les apps surveillées doivent s'ouvrir normalement, aucun écran de blocage nōto ne reste.
3. Réinstaller : ledger vide (nouvelle installation), libellé neutre, aucune activité `noto.reward.*` héritée.

## 7. Non-régression

- **Limite d'apps** sans quiz : budget épuisé → bouclier ; minuit → levé ; l'événement « Temps d'écran total » apparaît dans le briefing parent (une seule fois, aucune entrée parasite pour `noto.reward.*`).
- **Verrou cours** : pendant un bloc, 1 min d'usage → tout est bloqué ; un quiz ne lève rien ; après le bloc → levé (ou au foreground suivant).
- Après une synchronisation scolaire réussie (pull-to-refresh sur l'accueil parent), log `Class lock resynced after school sync` si le verrou est actif.
- Désactiver le verrou cours n'arrête **pas** la limite d'apps (le code ne passe plus jamais `stopMonitoring([])`, qui arrête tout).

## À vérifier une fois sur appareil (non vérifiable ici)

- `@objc(DeviceActivityMonitorExtension)` sans module + `NSExtensionPrincipalClass = NotoDeviceActivity.DeviceActivityMonitorExtension` : l'extension est bien chargée avec les nouvelles branches (un log `[noto][reward]` côté extension suffit).
- `startMonitoring` / `stopMonitoring` appelés depuis l'extension (fin de cours, budget épuisé).
- `repeats: false` avec un début `maintenant` à la seconde près : l'activité démarre immédiatement.
- `intervalDidEnd` des activités récompense à 23:59, et après un `stopMonitoring` (fusion) : le nom fusionné est inconnu du ledger, rien n'est rebloqué.
- Lecture croisée du bouclier : l'app lit `ManagedSettingsStore().shield` posé par l'**extension** (budget épuisé). Tout le choix « débloquer » vs `budgetNotSpent` en dépend (même mécanisme que `clearIfOutsideClassHours` pour le store nommé).
- Limite de 20 : `DeviceActivityCenter().activities.count` reste ≤ 19 (1 limite + ≤ 14 demi-journées + ≤ 3 récompenses + 1 transitoire).
