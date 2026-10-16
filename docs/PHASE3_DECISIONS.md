# Phase 3 — décisions à valider

Rédigé le 16/10/2026, à la clôture de la Phase 3 (PR #46 à #52 fusionnées).

Chaque point ci-dessous est une **recommandation**, pas une décision. Rien n'a été modifié dans le code pour l'appliquer : chaque entrée reste **à valider par Julien**. La colonne « État du code » décrit ce qui est livré aujourd'hui sur `master`, avec les références `fichier:ligne` relevées au moment de la rédaction (elles peuvent glisser avec les prochains commits).

Pour trancher : cocher une case par point, compléter « Réponse de Julien » si besoin, puis ouvrir une PR par lot de changements de code qui en découlent.

## Récapitulatif

| # | Sujet | Déjà tranché dans le code ? | Recommandation (résumé) | Décision |
|---|---|---|---|---|
| 1 | Enregistrement celyn : app=noto vs profil générique école | Oui | Valider app=noto a posteriori | à valider par Julien |
| 2 | Niveau scolaire côté celyn : colonne grade + ?grade= sur /lot, ou nouvel endpoint /bank | Oui | Garder /bank, c'est l'option que le brief recommandait déjà | à valider par Julien |
| 3 | Filtre de mots sensibles : exception pour le contenu scolaire | En partie | Accepter l'exception côté celyn avec un jeu de règles isSensitiveSchoolText, appliqué seulement aux items du… | à valider par Julien |
| 4 | Plafond vs bonus veille de contrôle | Oui | Valider le bonus au-dessus du plafond, ne pas monter le plafond à 25, puis retirer le commentaire « awaiting » | à valider par Julien |
| 5 | Fenêtre de rejeu : .ever vs même jour | Oui | Garder .ever par défaut | à valider par Julien |
| 6 | Règle d'échec Leitner : retour en boîte 1 vs descente d'une boîte | Oui | Passer le défaut à .demoteOne, sans en faire un réglage parent | à valider par Julien |
| 7 | Ajouter « devoir surveillé » aux mots-clés d'examen | Non | L'ajouter, au singulier et au pluriel : .phrase("devoir surveille") et .phrase("devoirs surveilles") | à valider par Julien |
| 8 | Persister ScheduleEntry.isTest depuis Pronote | Non | Oui : ajouter var isTest: Bool = false à ScheduleEntry, le remplir dans PronoteSyncService.syncSchedule, et l… | à valider par Julien |
| 9 | V1 = QCM à 4 choix uniquement (short et order reportés) | Oui | Valider | à valider par Julien |
| 10 | Abandonner NotoSchemaV2.swift au profit d'ajouts à V1 | Oui | Valider officiellement la correction du plan et mettre à jour docs/PLAN_REVISIONS_KMP_ANDROID.md | à valider par Julien |
| 11 | Critère d'acceptation « aucun nouveau flux réseau » devient « aucun nouvel hôte, aucune donnée personnelle » ; revoir PrivacyInfo | En pratique, oui | Accepter la nouvelle formulation, en ajoutant : « tout POST est déclenché par une action parent et ne contien… | à valider par Julien |
| 12 | Verrou enfant : garder l'accès ouvert sans PIN ou exiger un PIN | En partie | Exiger un PIN | à valider par Julien |
| 13 | Génération via l'API Claude dans l'app désactivée en V1 ; génération hors ligne par tools/generate-questions | Oui | Valider : pas d'appel à un LLM distant depuis l'app en V1 | à valider par Julien |
| 14 | Rejeu après une tentative bâclée ou échouée | Non pour les minutes, oui pour l'XP | Bloquer aussi les minutes : passer passedOnly à false dans la règle 4 | à valider par Julien |
| 15 | QuizItem issus des devoirs (RGPD) | Oui | Valider l'option (a) et ne pas ajouter de owner: Child? sur QuizItem | à valider par Julien |

---

## 1. Enregistrement celyn : app=noto vs profil générique école

**Statut : à valider par Julien**

**État du code.** Oui, tranché : app=noto en constante, seul consommateur accepté par l'endpoint bank (Noto/Services/CultureAPI/QuizAPIClient.swift:19-20, envoyé L62). Le contrat est présenté comme conclu : « Contract: celyn docs/quiz-v2-contrat.md §11 (agreed 15 Oct 2026, amended the same day) » (QuizAPIClient.swift:4-7). La question culture du jour passe par app=keskonfe (QuizAPIClient.swift:97, L105). Le « stop and report » du contrat a donc été levé dans les faits.

**Recommandation.** Valider app=noto a posteriori. Demander côté celyn que cette valeur soit adossée à un profil générique « école » (règles grade, filtre, review) plutôt qu'à du code spécifique à nōto, et mettre à jour noto-integration-spec.md:3 et :259-265 pour supprimer la contradiction.

**Justification.** Le client, le cache (QuizBankStore) et les tests sont déjà livrés contre app=noto. Revenir en arrière coûterait une PR des deux côtés sans aucun gain pour l'utilisateur. Le risque est seulement documentaire (deux specs qui se contredisent) et architectural côté celyn. Un profil générique en interne règle le second point sans toucher au client iOS.

**Décision**

- [ ] Validé tel quel
- [ ] Validé avec modification
- [ ] Refusé

Réponse de Julien : _…_

---

## 2. Niveau scolaire côté celyn : colonne grade + ?grade= sur /lot, ou nouvel endpoint /bank

**Statut : à valider par Julien**

**État du code.** Oui, tranché : nouvel endpoint GET /quiz/v2/bank?app=noto&grade=…&subject=&theme=&limit=&updatedSince= (QuizAPIClient.swift:54-89). Les DTO portent grade, subject, theme et notion (QuizAPIClient.swift:290-358). La synchro est incrémentale par niveau (QuizBankStore, appelée depuis ChildHomeView.swift:156). /lot reste sans niveau et sert seulement keskonfe (QuizAPIClient.swift:99-106).

**Recommandation.** Garder /bank, c'est l'option que le brief recommandait déjà. Ne pas ajouter ?grade= sur /lot.

**Justification.** Les révisions ont besoin d'un catalogue stable et paginé par niveau, matière et thème, avec high-water mark et suppressions (removed). /lot est un tirage quotidien daté : ce n'est pas le même objet. Mélanger les deux compliquerait le cache et la logique Leitner, qui repose sur des questionKey stables.

**Décision**

- [ ] Validé tel quel
- [ ] Validé avec modification
- [ ] Refusé

Réponse de Julien : _…_

---

## 3. Filtre de mots sensibles : exception pour le contenu scolaire

**Statut : à valider par Julien**

**État du code.** En partie, côté nōto seulement. Les items celyn ou banque ne passent par aucun filtre lexical sur l'appareil : QuizBankMapper.problem ne fait que des contrôles structurels (QuizBankStore.swift:23-35). La banque embarquée contient déjà « guerre » 9 fois (Noto/Resources/questions/*.json). La génération sur l'appareil a sa propre liste sensitivePrefixes (QuizGenerator.swift:397-400 : suicide, automutilation, porno, drogue et insultes), qui n'inclut ni guerre, ni victime, ni mort, ni élève. Côté celyn (isSensitiveText, core.ts:252-316), le repo ne permet pas de savoir ce qui a été fait.

**Recommandation.** Accepter l'exception côté celyn avec un jeu de règles isSensitiveSchoolText, appliqué seulement aux items du bank (grade + curriculum_theme) marqués reviewed. Garder bloqués les termes sexuels, d'automutilation et de drogue, et garder le filtre strict pour tout le reste (lot, actu). Côté nōto, ne rien ajouter.

**Justification.** Sans cette exception, une grande partie du programme d'histoire et d'EMC devient impossible : guerres mondiales, Révolution, génocides. La relaxation reste bornée : contenu rattaché au programme, relu (reviewConfidence ≥ 0,9, QuizBankStore.swift:12-17) et filtré par niveau. nōto se comporte déjà ainsi pour sa banque embarquée. Celyn est la seule barrière pour les items distants, donc la règle doit y être explicite et testée.

**Décision**

- [ ] Validé tel quel
- [ ] Validé avec modification
- [ ] Refusé

Réponse de Julien : _…_

---

## 4. Plafond vs bonus veille de contrôle

**Statut : à valider par Julien**

**État du code.** Oui, le défaut du brief est implémenté : le bonus s'ajoute au-dessus du plafond, une fois par jour (RewardPolicy.swift:181-189 ; le plafond ne compte que la base, L173-179, en retirant bonusMinutes stocké, QuizAttempt.swift:22-24). Défauts : dailyCap 20, examEveBonus 5, activé (RewardPolicy.swift:39-40). Le parent peut modifier les deux, et le texte affiché dit « +N min une fois par jour, au-delà du plafond » (RevisionSettingsView.swift:186-204). Le commentaire « Default awaiting Julien's decision » est toujours présent (RewardPolicy.swift:183).

**Recommandation.** Valider le bonus au-dessus du plafond, ne pas monter le plafond à 25, puis retirer le commentaire « awaiting ».

**Justification.** Avec le barème 10/5/5, la base atteint exactement 20 : un bonus compté dans le plafond ne serait jamais gagné. Monter le plafond à 25 donnerait 5 minutes de plus tous les jours, veille de contrôle ou pas, ce qui fausse le signal. Le bonus ponctuel récompense précisément la révision avant un contrôle, et le parent peut le désactiver.

**Décision**

- [ ] Validé tel quel
- [ ] Validé avec modification
- [ ] Refusé

Réponse de Julien : _…_

---

## 5. Fenêtre de rejeu : .ever vs même jour

**Statut : à valider par Julien**

**État du code.** Oui : défaut .ever (RewardPolicy.swift:41), modifiable par le parent avec « Jamais » / « Le même jour » (RevisionSettingsView.swift:218-220). La comparaison porte sur l'ensemble des clés, sans tenir compte de l'ordre (RewardPolicy.swift:202-209). Le garde-fou XP utilise la même fenêtre (Gamification.swift:143).

**Recommandation.** Garder .ever par défaut.

**Justification.** Avec .sameDay, un enfant peut rejouer chaque jour le même lot appris par cœur et toucher le palier complet. .ever ne bloque que le même ensemble exact de questions : il ne bloque pas une notion due en Leitner tirée avec d'autres questions. Le coût pour l'enfant est donc faible tant que la banque compte au moins 15 questions par thème.

**Décision**

- [ ] Validé tel quel
- [ ] Validé avec modification
- [ ] Refusé

Réponse de Julien : _…_

---

## 6. Règle d'échec Leitner : retour en boîte 1 vs descente d'une boîte

**Statut : à valider par Julien**

**État du code.** Oui, de fait : .resetToBoxOne par défaut (SpacedRepetition.swift:22-23). Le seul appel, QuizSession.swift:352-353, ne passe pas le paramètre failure. .demoteOne existe et est testable mais n'est branché nulle part. Le commentaire « Parent-configurable » (SpacedRepetition.swift:13) est donc faux : rien dans RewardConfig ni dans RevisionSettingsView ne permet de le régler.

**Recommandation.** Passer le défaut à .demoteOne, sans en faire un réglage parent. Corriger le commentaire de SpacedRepetition.swift:13.

**Justification.** Une notion est jugée fausse dès qu'un seul de ses items est faux (notionOutcome, SpacedRepetition.swift:65-67). Avec le retour en boîte 1, une seule erreur d'inattention efface 16 jours d'acquis, et le badge reste quand même (masteredAt est permanent) : c'est décourageant et incohérent. Descendre d'une boîte reste exigeant sans être punitif. C'est un paramètre pédagogique, pas un choix de famille : l'exposer au parent alourdirait l'écran pour rien. Si Julien préfère garder la boîte 1, il suffit de corriger le commentaire.

**Décision**

- [ ] Validé tel quel
- [ ] Validé avec modification
- [ ] Refusé

Réponse de Julien : _…_

---

## 7. Ajouter « devoir surveillé » aux mots-clés d'examen

**Statut : à valider par Julien**

**État du code.** Non : l'entrée est commentée, « Suggestion, pending Julien's decision » (ExamKeywordDetector.swift:24-25). Les abréviations « DS », « DS2 » sont déjà couvertes par .numbered("ds") (L21).

**Recommandation.** L'ajouter, au singulier et au pluriel : .phrase("devoir surveille") et .phrase("devoirs surveilles").

**Justification.** C'est l'intitulé exact utilisé dans les cahiers de textes de collège et de lycée quand le DS n'est pas abrégé. La règle .phrase exige les deux mots contigus (le pliage gère les accents), donc « devoir » seul ne déclenche rien et le risque de faux positif est quasi nul. Sans le pluriel, « devoirs surveillés » passerait à côté, car les tokens sont comparés exactement. Le seul effet d'un faux positif serait un bonus de 5 minutes une fois par jour.

**Décision**

- [ ] Validé tel quel
- [ ] Validé avec modification
- [ ] Refusé

Réponse de Julien : _…_

---

## 8. Persister ScheduleEntry.isTest depuis Pronote

**Statut : à valider par Julien**

**État du code.** Non : ce n'est pas persisté. ScheduleSnapshot force isTest: false (QuizSnapshots.swift:194-197, commentaire L37-38), donc la branche emploi du temps de hasExamTomorrow (ExamKeywordDetector.swift:64-66) ne peut jamais se déclencher. La donnée existe pourtant déjà côté Pronote : PronoteTypes.swift:69, PawnoteBridge.swift:279, PronoteClient.swift:210 (estDevoir). Aucun champ isTest dans SchoolData.swift ni PronoteSyncService.swift.

**Recommandation.** Oui : ajouter var isTest: Bool = false à ScheduleEntry, le remplir dans PronoteSyncService.syncSchedule, et le recopier dans ScheduleSnapshot.init(_ entry:).

**Justification.** Un champ ajouté avec une valeur par défaut est une migration légère, comme Child.specialties : c'est conforme au mode d'évolution de NotoSchemaV1.swift:40-50. Le signal posé par l'établissement est plus fiable que les mots-clés des devoirs, et le code qui le consomme est déjà écrit et testé. Pour les autres connecteurs (ENT, École Directe, Skolengo), la valeur reste false et rien ne change.

**Décision**

- [ ] Validé tel quel
- [ ] Validé avec modification
- [ ] Refusé

Réponse de Julien : _…_

---

## 9. V1 = QCM à 4 choix uniquement (short et order reportés)

**Statut : à valider par Julien**

**État du code.** Oui : QuizFormat ne contient que .mcq (QuizItem.swift:12-15). Les 4 choix sont exigés partout : QuizBankStore.swift:26-31, QuizGenerator.swift:259, QuizSession.swift:368, DailyCultureQuestion.swift:59-60. Toute l'interface (QuizView) suppose 4 boutons.

**Recommandation.** Valider. Rouvrir short et order seulement en V2, et seulement si celyn fait d'abord évoluer son contrat.

**Justification.** Le contrat celyn (zod, Set(trimmed).size === 4), la clé questionKey et toute la correction sur l'appareil reposent sur 4 choix. Ajouter un format demanderait un enum additif plus de nouveaux validateurs, de nouvelles vues et un nouveau calcul de clé, pour un bénéfice pédagogique réel mais pas indispensable à l'acceptation de la Phase 3. L'enum laisse la porte ouverte sans migration lourde.

**Décision**

- [ ] Validé tel quel
- [ ] Validé avec modification
- [ ] Refusé

Réponse de Julien : _…_

---

## 10. Abandonner NotoSchemaV2.swift au profit d'ajouts à V1

**Statut : à valider par Julien**

**État du code.** Oui, fait : il n'y a pas de NotoSchemaV2. QuizItem, QuizAttempt, NotionMastery (3.1) et StreakJoker (3.6) ont été ajoutés à la liste de NotoSchemaV1, avec des champs additifs à valeur par défaut (NotoSchemaV1.swift:40-50). La raison est documentée en L8-18 : V1 n'est pas figé, et un plan de migration casserait le lancement.

**Recommandation.** Valider officiellement la correction du plan et mettre à jour docs/PLAN_REVISIONS_KMP_ANDROID.md.

**Justification.** Créer un V2 sans avoir d'abord figé V1 ferait échouer la migration étagée au lancement (« unknown model version ») : le risque est réel, il ne s'agit pas d'un détail. Tant que les changements restent additifs, la migration légère suffit. La procédure « figer V1 puis V2 » reste notée pour le premier changement qui ne le sera pas.

**Décision**

- [ ] Validé tel quel
- [ ] Validé avec modification
- [ ] Refusé

Réponse de Julien : _…_

---

## 11. Critère d'acceptation « aucun nouveau flux réseau » devient « aucun nouvel hôte, aucune donnée personnelle » ; revoir PrivacyInfo

**Statut : à valider par Julien**

**État du code.** En pratique, oui. Les seuls nouveaux appels vont vers celyn.io, un hôte déjà utilisé (QuizAPIClient.swift:31), en GET avec seulement des paramètres publics de programme (QuizAPIClient.swift:9-17, L61-76). La génération se fait entièrement sur l'appareil (FoundationModels, sans URLSession dans FoundationModelsQuizGenerator.swift). Le bilan hebdomadaire est une notification locale. Il existe un POST report() avec un identifiant d'appareil aléatoire (QuizAPIClient.swift:119-145), mais rien ne l'appelle. PrivacyInfo a été mis à jour en 3.7 : raison 1C8F.1 pour les UserDefaults du groupe d'apps (commit bf145b66).

**Recommandation.** Accepter la nouvelle formulation, en ajoutant : « tout POST est déclenché par une action parent et ne contient aucune donnée liée à l'enfant ». Avant de brancher report(), revérifier PrivacyInfo.xcprivacy : l'identifiant d'appareil envoyé (x-device-id) pourrait devoir être déclaré comme Device ID.

**Justification.** La règle d'origine est déjà enfreinte, pour une bonne raison : la synchro du bank est indispensable à la mise à jour du contenu. La nouvelle formulation dit ce qui compte vraiment pour le RGPD et pour l'App Review : pas de nouveau destinataire, pas de donnée sur l'enfant. Le seul point ouvert est le futur signalement : il envoie un identifiant par installation, sujet à déclaration dans le manifeste.

**Décision**

- [ ] Validé tel quel
- [ ] Validé avec modification
- [ ] Refusé

Réponse de Julien : _…_

---

## 12. Verrou enfant : garder l'accès ouvert sans PIN ou exiger un PIN

**Statut : à valider par Julien**

**État du code.** En partie. L'accès ouvert sans PIN est toujours là : sans PIN configuré, la roue dentée ouvre directement les Réglages (ChildHomeView.swift:84-91). Mais tout nouvel appareil enfant passe obligatoirement par la création du PIN pendant l'onboarding : rôle enfant, puis .parentGateSetup (OnboardingView.swift:116-118, L42), et annuler ramène au choix du rôle. L'accès ouvert ne concerne donc que les appareils mis à jour depuis une version d'avant le PIN. Or les Réglages ouvrent RevisionSettingsView (SettingsView.swift:165-166), qui écrit la RewardConfig dans le groupe d'apps de l'appareil de l'enfant.

**Recommandation.** Exiger un PIN. S'il n'y en a pas, la roue dentée ouvre ParentGateView(mode: .setUp) au lieu des Réglages, puis les Réglages une fois le PIN enregistré. Plus de cas où l'accès reste ouvert.

**Justification.** Depuis la 3.7, les Réglages contiennent le barème, le plafond (jusqu'à 60 min) et le bonus. Depuis la 3.4, ces réglages déverrouillent de vrais apps. Laisser l'accès ouvert permet à l'enfant d'un appareil mis à jour de s'attribuer lui-même du temps d'écran. Le risque de verrouillage définitif, qui justifiait l'accès ouvert, disparaît si on propose la création du PIN au lieu de bloquer. C'est le même niveau de confiance que l'onboarding actuel.

**Décision**

- [ ] Validé tel quel
- [ ] Validé avec modification
- [ ] Refusé

Réponse de Julien : _…_

---

## 13. Génération via l'API Claude dans l'app désactivée en V1 ; génération hors ligne par tools/generate-questions

**Statut : à valider par Julien**

**État du code.** Oui, dans l'app : aucune dépendance ni appel vers Anthropic ou Claude dans Noto/. La 3.3 génère seulement sur l'appareil (FoundationModelsQuizGenerator.swift, import FoundationModels ; « the request never leaves the device », QuizGenerator.swift:7-11). En revanche, tools/generate-questions/ n'existe pas dans le repo, alors que la banque embarquée existe (Noto/Resources/questions/6e.json, 2nde.json).

**Recommandation.** Valider : pas d'appel à un LLM distant depuis l'app en V1. Versionner tools/generate-questions/ (ou documenter où il vit et comment la banque est régénérée et relue) avant d'étendre la banque à d'autres niveaux.

**Justification.** Un appel distant enverrait le texte des devoirs, une donnée personnelle de l'enfant, chez un tiers : c'est incompatible avec le critère de la décision 11 et ça poserait une vraie question RGPD pour des mineurs. Le reste est couvert sur l'appareil par la génération ancrée dans le texte des devoirs. L'absence de l'outil dans le repo est un risque de reproductibilité : on ne peut ni régénérer ni auditer la banque relue.

**Décision**

- [ ] Validé tel quel
- [ ] Validé avec modification
- [ ] Refusé

Réponse de Julien : _…_

---

## 14. Rejeu après une tentative bâclée ou échouée

**Statut : à valider par Julien**

**État du code.** Pour les minutes, non : la règle 4 ne regarde que les tentatives réussies précédentes (RewardPolicy.swift:161-165, passedOnly: true). Une tentative .tooFast ou .belowThreshold a passed = false (QuizSnapshots.swift:210-214) et ne bloque donc pas un rejeu identique fait lentement. Pour l'XP, c'est déjà tranché : Gamification bloque l'XP de tout rejeu, y compris après un échec (Gamification.swift:138-143). Le prérequis du brief est déjà livré : AttemptSnapshot porte la raison du refus (denial) depuis la 3.7 (QuizSnapshots.swift:89-91).

**Recommandation.** Bloquer aussi les minutes : passer passedOnly à false dans la règle 4. N'importe quelle tentative précédente avec le même ensemble de clés, dans la fenêtre de rejeu, compte alors comme rejeu, comme pour l'XP. Garder .emptyQuiz et .tooShort hors du calcul : ces tentatives n'ont rien révélé de façon fiable.

**Justification.** Chaque correction montre les bonnes réponses. Aujourd'hui, la combine « bâcler, lire la correction, rejouer lentement » donne le palier complet : c'est exactement la triche que le seuil de durée et la règle 4 doivent empêcher. Aligner les minutes sur la règle XP simplifie le modèle (une seule définition du rejeu) et ne coûte presque rien à l'enfant honnête : le tirage suivant propose un autre ensemble de questions. Le changement tient en une ligne, plus des tests.

**Décision**

- [ ] Validé tel quel
- [ ] Validé avec modification
- [ ] Refusé

Réponse de Julien : _…_

---

## 15. QuizItem issus des devoirs (RGPD)

**Statut : à valider par Julien**

**État du code.** Oui, tranché par l'option (a). Les questions .homework et .generated ne sont jamais insérées dans QuizItem : ce sont des QuizQuestion éphémères (QuizItem.swift:17-23, QuizGenerator.swift:145). Seule leur clé « generated#<homeworkKey> » est conservée (QuizGenerator.swift:406-408), dans QuizAttempt.questionKeys. Cette valeur est supprimée en cascade avec l'enfant (Child.swift:76). homeworkKey est un SHA256 de la matière, de la date et de la consigne (QuizSnapshots.swift:17-29) : rien n'est stocké en clair.

**Recommandation.** Valider l'option (a) et ne pas ajouter de owner: Child? sur QuizItem. Si un jour on veut mettre en cache les questions générées, utiliser un @Model distinct appartenant à l'enfant, avec suppression en cascade.

**Justification.** Les données personnelles ne sortent jamais du graphe de l'enfant. L'effacement est donc garanti par les cascades existantes, sans relation optionnelle à maintenir. QuizItem reste une table partagée et non personnelle, purgeable par la synchro du bank. Le hash conservé est pseudonyme et disparaît avec l'enfant.

**Décision**

- [ ] Validé tel quel
- [ ] Validé avec modification
- [ ] Refusé

Réponse de Julien : _…_

---

## Note : audit du manifeste de confidentialité (clôture Phase 3)

Lié au point 11, sans le trancher. L'audit de `Noto/Resources/PrivacyInfo.xcprivacy` contre le code Phase 3 ne demande aucun changement du manifeste de l'app : aucun nouveau type de donnée collectée, aucun nouveau domaine, et la raison `1C8F.1` des UserDefaults du groupe d'apps est déjà déclarée. Le seul manque concernait l'extension `NotoDeviceActivity`, qui lit et écrit les UserDefaults du groupe d'apps (`Shared/`) sans manifeste propre ; elle a maintenant `NotoDeviceActivity/PrivacyInfo.xcprivacy`. Le détail est dans la PR de clôture. Le point « Device ID pour `report()` » reste ouvert et ne s'applique que le jour où `report()` est branché.
