# Synchro famille (phase 9) — parcours de validation sur deux iPhone

La synchro famille relie le téléphone de l'enfant (mode enfant) à celui du parent (mode parent) par une zone CloudKit partagée, chiffrée de bout en bout dans l'iCloud du parent. Cadrage : `/mnt/project-files/sync-famille/CADRAGE.md`. La CI ne peut pas la tester : il faut deux iPhone et **deux comptes iCloud différents** (un pour le parent, un pour l'enfant). Le Simulateur ne sert pas : il ne reçoit pas d'invitation CloudKit de façon fiable, et le verrou des cours n'y tourne pas.

## 0. Préalables côté Apple (une fois)

1. **Container** : dans Certificates, Identifiers & Profiles › Identifiers › iCloud Containers, créer `iCloud.fr.noto.app`.
2. **App ID** `fr.noto.app` : cocher iCloud › CloudKit, et y associer le container.
3. **Profil** : `node ci_scripts/asc-profile.mjs fr.noto.app | gh secret set PROVISIONING_PROFILE_NOTO --repo jtassy-stack/noto` (clé ASC dans `.claude/asc/.env`). Le script régénère « noto appstore » par l'API App Store Connect avec les mêmes certificats et vérifie qu'il porte `iCloud.fr.noto.app`. Le profil de l'extension ne change pas.
4. **Entitlements** : dans `project.yml` (`com.apple.developer.icloud-container-identifiers` + `icloud-services: CloudKit`). À fusionner seulement après l'étape 3, sinon l'archive TestFlight échoue.
5. **Drapeau** : `FAMILY_SYNC_ENABLED = YES` dans `Config.xcconfig` (ou dans Infisical pour la CI). Tant qu'il vaut `NO`, aucun appel CloudKit ne part et l'écran « Relier le téléphone » n'apparaît pas.
6. **Schéma** : un premier aller-retour en build Debug crée les types en environnement *Development* : `QuizAttempt`, `NotionMastery`, `StreakJoker`, `DayMinutes`, `RewardRules`. Dans la console CloudKit, vérifier que les champs sont bien chiffrés, puis **Deploy Schema Changes** vers *Production* avant tout build TestFlight (TestFlight utilise la Production).

## Fiche de session

| Champ | Valeur |
|---|---|
| Date | |
| iPhone parent (modèle, iOS, compte iCloud) | |
| iPhone enfant (modèle, iOS, compte iCloud) | |
| Build (TestFlight n° ou Debug + commit) | |
| Enfant (prénom de test, classe) | |
| Testeur | |

## 1. Relier

| # | Étape | Attendu | OK |
|---|---|---|---|
| 1.1 | Parent : Réglages › enfant › « Relier le téléphone de X » | Écran « Relier le téléphone », statut « n'est pas relié » | |
| 1.2 | « Envoyer l'invitation » → Messages vers le compte iCloud de l'enfant | Feuille de partage système, titre « nōto » (jamais le prénom) | |
| 1.3 | Enfant : ouvrir le lien (nōto en mode enfant) | Alerte « Relier ton téléphone à celui de tes parents ? » (tutoiement) | |
| 1.4 | Accepter | Pas d'erreur ; Réglages › Révisions affiche « Ce téléphone est relié au vôtre » et les réglages sont grisés | |
| 1.5 | Parent : rouvrir « Relier le téléphone » | « relié depuis le … », « Synchronisé … », bouton « Synchroniser maintenant » | |
| 1.6 | Ouvrir l'invitation sur le téléphone du **parent** | Alerte « Invitation pour le téléphone de votre enfant », rien n'est accepté | |

## 2. Résultats enfant → parent

| # | Étape | Attendu | OK |
|---|---|---|---|
| 2.1 | Enfant : faire et réussir un quiz, puis passer nōto en arrière-plan et le rouvrir | — | |
| 2.2 | Parent : ouvrir nōto (ou « Synchroniser maintenant ») | Accueil › « Cette semaine » : jours de révision, notions, « Dernières données du téléphone de X : il y a … » (date de l'envoi par le téléphone de l'enfant, pas de la synchro du parent) | |
| 2.3 | Parent : onglet Écran | Minutes du jour et 7 derniers jours ; plus de « sur l'appareil où X fait ses quiz » | |
| 2.4 | Enfant : quiz réussi **pendant un cours** | Parent, Écran : « N min gagnées pendant les cours, gardées pour après les cours » ; sur l'enfant, le verrou des cours reste en place | |
| 2.5 | Parent : Réglages › Révisions (stats) | Quiz faits, série, dernier quiz ; carte confidentialité « arrivent du téléphone relié … nōto n'y a pas accès » | |
| 2.6 | Parent : « Voir l'appli de X » (vision enfant) | Bandeau « viennent de son téléphone relié » ; série et badges remplis | |
| 2.7 | Parent : quiz parent | Phrase de comparaison avec les notions de l'enfant | |
| 2.8 | Rouvrir deux fois de suite côté enfant sans nouveau quiz | Rien n'est renvoyé (logs : aucun « a record was not sent ») ; côté parent, pas de quiz en double | |

## 3. Règles parent → enfant

| # | Étape | Attendu | OK |
|---|---|---|---|
| 3.1 | Parent : Réglages › Révisions, changer le plafond et couper la question culture, fermer | Carte « Ces règles s'appliquent aussi sur le téléphone relié » | |
| 3.2 | Enfant : rouvrir nōto | Nouveau plafond dans la cagnotte ; question culture absente de l'accueil enfant | |
| 3.3 | Enfant : Réglages › Révisions (code parent) | Valeurs du parent, non modifiables | |

## 4. Arrière-plan

| # | Étape | Attendu | OK |
|---|---|---|---|
| 4.1 | Laisser les deux téléphones quelques heures sans ouvrir nōto, actualisation en arrière-plan activée, faire un quiz juste avant | En rouvrant chez le parent, « Dernières données … » indique une heure où l'app de l'enfant était fermée (best effort : iOS décide) | |
| 4.3 | Enfant en mode avion, parent : « Synchroniser maintenant » | « Synchronisé à l'instant » mais « Dernières données » garde l'heure du dernier envoi de l'enfant | |
| 4.2 | Xcode : `e -l objc -- (void)[[BGTaskScheduler sharedScheduler] _simulateLaunchForTaskWithIdentifier:@"fr.noto.app.familySync"]` | La synchro tourne, `familySyncLastSyncedAt` change | |

## 5. Délier

| # | Étape | Attendu | OK |
|---|---|---|---|
| 5.1 | Parent : « Délier le téléphone de X » | Les quiz, notions et jokers reçus disparaissent de l'Accueil et de l'Écran ; ceux faits sur le téléphone du parent restent | |
| 5.2 | Enfant : rouvrir nōto | Réglages › Révisions redevient modifiable, plus de mention « relié » | |
| 5.3 | Parent : supprimer un enfant relié en mode avion, puis relancer avec le réseau | La zone est supprimée au lancement suivant ; l'enfant perd l'accès | |

## 6. Confidentialité (à vérifier dans la console CloudKit)

- Les noms d'enregistrement et de zone sont opaques (`enfant-<uuid>`, ids sans prénom).
- Tous les champs sont dans `encryptedValues` : la console n'en affiche pas le contenu.
- Aucun enregistrement ne contient de clé de question, de réponse, de note, de message ni de photo.
- `PrivacyInfo.xcprivacy` : inchangé. Les données vont dans l'iCloud de la famille, chiffrées de bout en bout, sans que l'éditeur y ait accès : au sens d'Apple, elles ne sont pas « collectées ». La politique de confidentialité publiée doit en revanche le dire (voir la PR 9.4).
