# Phase 3 — parcours de validation sur iPhone réel

Dernier critère d'acceptation de la Phase 3 (`docs/PLAN_REVISIONS_KMP_ANDROID.md`, « Critères d'acceptation phase 3 ») :

> Parcours complet sur iPhone réel en mode enfant : quiz 6e et 2nde, minutes créditées, apps débloquées puis rebloquées, verrou cours intact.

Ce document est la procédure à dérouler, dans l'ordre. Il ne remplace pas `docs/TEST_REWARD.md`, qui détaille les cas limites du déblocage (fusion, désinstallation, sans autorisation…) et les lignes de log attendues : on y renvoie au lieu de les recopier.

DeviceActivity, ManagedSettings et FamilyControls ne fonctionnent **pas** dans le Simulateur. L'extension `NotoDeviceActivity` n'est embarquée que pour `iphoneos` (`project.yml`). Tout ce qui suit se fait donc sur un iPhone.

## Fiche de session

| Champ | Valeur |
|---|---|
| Date | |
| iPhone (modèle, iOS) | |
| Build (TestFlight n° ou Debug Xcode + commit) | |
| Enfant 6e (prénom de test) | |
| Enfant 2nde (prénom de test) | |
| Testeur | |

## Valeurs par défaut attendues

Elles viennent de `RewardConfig()` (`Noto/Services/Quiz/RewardPolicy.swift`). Si le parent les a modifiées, adapter les résultats attendus.

| Réglage | Défaut |
|---|---|
| Barème des paliers | 1er quiz réussi 10 min, 2e 5 min, 3e 5 min, ensuite 0 |
| Seuil de réussite | 80 % (4/5) |
| Questions par quiz | 5 (`QuizSession.questionCount`), minimum 5 pour gagner des minutes |
| Durée minimale | 30 s, en dessous : 0 min |
| Plafond quotidien | 20 min (bonus non compris) |
| Bonus veille de contrôle | +5 min, une fois par jour, au-delà du plafond |
| Fenêtre de rejeu | « Jamais » (`.ever`) : un lot identique déjà réussi ne rapporte plus rien |

## 0. Prérequis

| # | Étape | OK |
|---|---|---|
| 0.1 | iPhone sous iOS 17.4 ou plus (iOS 26 pour tester aussi les questions générées sur l'appareil, Phase 3.3), mode développeur activé si build Xcode. | ☐ |
| 0.2 | Build installé : soit TestFlight (Julien lance `/asc-ship`), soit `xcodegen generate` puis Cmd+R sur l'iPhone, schéma `Noto`. | ☐ |
| 0.3 | Console.app ouverte sur l'iPhone, filtre `noto` (processus `Noto` et `NotoDeviceActivity`). Voir `docs/TEST_REWARD.md` § Préparation. | ☐ |
| 0.4 | La famille contient deux enfants, l'un en **6e**, l'autre en **2nde** (niveau visible dans la fiche enfant). Les deux niveaux ont une banque embarquée (`Noto/Resources/questions/6e.json`, `2nde.json`), le quiz marche donc même hors ligne. | ☐ |
| 0.5 | Au moins un enfant a un emploi du temps synchronisé avec un cours dans la journée du test (pour l'étape 5). | ☐ |

## 1. Configuration côté parent

| # | Étape | Résultat attendu | OK |
|---|---|---|---|
| 1.1 | Mode parent → Réglages → Temps d'écran : autoriser Screen Time. | La demande d'autorisation système s'affiche, puis l'état « autorisé ». | ☐ |
| 1.2 | Choisir 1 ou 2 apps « loisirs » faciles à ouvrir (Calculatrice, Météo). | Sélection enregistrée. | ☐ |
| 1.3 | Activer la limite d'apps avec le **plus petit budget** possible. | Limite active. | ☐ |
| 1.4 | Activer « Verrouillage pendant les cours ». | Libellé « Verrouillage pendant les cours activé » visible côté enfant ensuite. | ☐ |
| 1.5 | « Cet appareil appartient à » : choisir l'enfant **6e**. | Picker sur le prénom de l'enfant 6e. | ☐ |
| 1.6 | Réglages → Révisions : vérifier le barème `10 / 5 / 5`, plafond 20, bonus activé. | Valeurs par défaut affichées. | ☐ |
| 1.7 | Passer l'appareil en mode enfant. Si l'onboarding le propose, créer le **PIN parent**. | Accueil enfant : « Ta cagnotte », « Ta série », « Réviser (3 min) », emploi du temps du jour. | ☐ |
| 1.8 | Toucher la roue dentée. | Le PIN est demandé (si aucun PIN n'existe sur un appareil mis à jour, l'accès est ouvert : c'est la décision 12 de `docs/PHASE3_DECISIONS.md`, noter ce qui se passe). | ☐ |

## 2. Quiz 6e et minutes créditées

Épuiser d'abord le budget en utilisant les apps surveillées jusqu'à l'écran de blocage Screen Time (voir l'astuce de `docs/TEST_REWARD.md`). Sinon les minutes restent « en attente » (§1 bis de `TEST_REWARD.md`), ce qui est normal mais ne teste pas le déblocage.

| # | Étape | Résultat attendu | OK |
|---|---|---|---|
| 2.1 | Vérifier que les apps surveillées affichent l'écran de blocage. | Bloquées. | ☐ |
| 2.2 | « Réviser (3 min) ». Lire les 5 questions. | Questions de 6e uniquement (matières et thèmes du programme de 6e), 4 choix chacune, explication après chaque réponse. | ☐ |
| 2.3 | Répondre juste à au moins 4 questions sur 5, en plus de 30 s. | Résultat « 4 / 5 » ou « 5 / 5 », « +10 min dans ta cagnotte », XP affichée. | ☐ |
| 2.4 | « Terminer ». | Cagnotte « 10 min », carte « Tes 10 min sont débloquées ». | ☐ |
| 2.5 | « Un autre quiz », réussi. | « +5 min ». Cagnotte 15 min. | ☐ |
| 2.6 | Troisième quiz réussi. | « +5 min ». Cagnotte 20 min (plafond atteint). | ☐ |
| 2.7 | Quatrième quiz réussi. | 0 min (plafond et barème épuisés). XP et progression du thème bougent quand même. | ☐ |
| 2.8 | Un quiz en moins de 30 s (répondre au hasard très vite). | 0 min, message « Tu as répondu super vite ! … ». | ☐ |
| 2.9 | Un quiz avec 3 bonnes réponses sur 5 ou moins. | 0 min, message « Il fallait 4 bonnes réponses pour gagner des minutes. … ». | ☐ |
| 2.10 | Mode parent (derrière le PIN) → Révisions. | Les quiz du jour apparaissent, minutes gagnées = 20, notions maîtrisées ou fragiles cohérentes. | ☐ |

Pour un quiz rejoué à l'identique (même lot de questions), le résultat attendu est 0 min. C'est difficile à provoquer à la main, car le tirage change à chaque fois : ce cas est couvert par les tests unitaires de `RewardPolicy`.

## 3. Apps débloquées puis rebloquées

| # | Étape | Résultat attendu | OK |
|---|---|---|---|
| 3.1 | Après 2.4, ouvrir une app surveillée. | Elle s'ouvre, sans écran de blocage. | ☐ |
| 3.2 | L'utiliser jusqu'à consommer les minutes débloquées (usage cumulé). | Log extension `[noto][reward] noto.reward.<uuid> used up — re-lock: yes`. | ☐ |
| 3.3 | Rouvrir l'app surveillée. | L'écran de blocage est revenu. L'accueil enfant revient au libellé neutre. | ☐ |

En cas d'échec, chercher `budgetNotSpent`, `noSelection` ou `notAuthorized` dans les logs (`docs/TEST_REWARD.md` § 1).

## 4. Quiz 2nde

| # | Étape | Résultat attendu | OK |
|---|---|---|---|
| 4.1 | Roue dentée → PIN → Réglages → Temps d'écran → « Cet appareil appartient à » : choisir l'enfant **2nde**. Revenir à l'accueil enfant. | Le prénom affiché et l'emploi du temps sont ceux de l'enfant 2nde. | ☐ |
| 4.2 | « Réviser (3 min) ». | Questions de 2nde uniquement, aucune question de 6e. | ☐ |
| 4.3 | Quiz réussi (≥ 4/5, > 30 s). | Résultat affiché, minutes calculées pour l'enfant 2nde. | ☐ |
| 4.4 | Noter la cagnotte affichée. | Le registre des minutes (`RewardLedger`) est **par appareil**, pas par enfant. Si 2 et 4 sont faits le même jour sur le même iPhone, noter si le plafond de l'enfant 2nde et le solde partagé se comportent comme prévu. Pour un test propre, faire l'étape 4 un autre jour ou sur un second iPhone. | ☐ |

Comportement observé (si différent de l'attendu) : _…_

## 5. Verrou cours intact

Pendant un créneau de cours de l'enfant lié à l'appareil. Détail et logs : `docs/TEST_REWARD.md` § 2.

| # | Étape | Résultat attendu | OK |
|---|---|---|---|
| 5.1 | Pendant le cours, utiliser une app 1 min. | Tout est bloqué par le verrou cours. | ☐ |
| 5.2 | Terminer un quiz réussi pendant le cours (le commencer juste avant si nōto est masqué). | Log `[noto][reward] in class: N min to reserve`. Accueil : « Tes minutes t'attendent après les cours ». | ☐ |
| 5.3 | Pendant le cours, ouvrir une app surveillée. | **Toujours bloquée.** Le crédit ne lève jamais le verrou cours (règle CLAUDE.md « Class lock is absolute »). | ☐ |
| 5.4 | Après la fin du cours (ou à la réouverture de nōto). | Log `released from reserve`, puis apps débloquées N min si le budget est épuisé. | ☐ |

## 6. Minuit (facultatif mais recommandé)

Suivre `docs/TEST_REWARD.md` § 3 : à 00:00, les activités `noto.reward.*` de la veille sont arrêtées et la cagnotte revient à 0 min.

| # | Étape | Résultat attendu | OK |
|---|---|---|---|
| 6.1 | Laisser des minutes non consommées, passer minuit. | Log `midnight reset: stopped N reward activities`, cagnotte 0 min le lendemain. | ☐ |

## 7. Confidentialité

| # | Étape | Résultat attendu | OK |
|---|---|---|---|
| 7.1 | Réglages iOS → Confidentialité et sécurité → Rapport de confidentialité des apps : activer, refaire un quiz et la synchro, puis ouvrir la fiche nōto. | Côté révisions, seul le domaine `celyn.io` apparaît (synchro de la banque en GET, question culture du jour). Les autres domaines sont ceux des connecteurs écoles déjà connus (Pronote, ENT…). | ☐ |
| 7.2 | iOS 26 : faire un quiz sur un enfant qui a des devoirs à venir. | Questions générées depuis les devoirs possibles, sans nouveau domaine dans le rapport (génération sur l'appareil). | ☐ |

## 8. Non-régression rapide

| # | Étape | Résultat attendu | OK |
|---|---|---|---|
| 8.1 | Repasser en mode parent : accueil, briefing, onglets École. | Rien de cassé. Item « Révisions » au ton parent (« Votre enfant… »). | ☐ |
| 8.2 | Limite d'apps sans quiz (`docs/TEST_REWARD.md` § 7). | Inchangée. | ☐ |

## Verdict

| Critère du plan | OK |
|---|---|
| Quiz 6e | ☐ |
| Quiz 2nde | ☐ |
| Minutes créditées | ☐ |
| Apps débloquées puis rebloquées | ☐ |
| Verrou cours intact | ☐ |

Si tout est coché, passer la ligne « 3 Révisions iOS » de la table « Suivi » (`docs/PLAN_REVISIONS_KMP_ANDROID.md`) à « fait », avec la date et le numéro de build.

Anomalies relevées (une ligne par anomalie, avec l'étape et le log) :

- _…_
