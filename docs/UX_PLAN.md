# UX/UI Plan — nōto

**Généré le** : 10 avril 2026
**Personas** : Nathalie (surprotecteur), Sophie C. (activités éducatives — priorité), Sophie M. (skim & go)
**Périmètre** : v2.x complet — Sprints A + B + C

---

## Persona Prioritaire : Sophie C. — Parent Activités Éducatives

Sophie, 41 ans, utilise nōto comme pont programme scolaire → ressources culturelles. Elle veut
une connexion automatique "son fils étudie la Rome antique → voici l'expo et le podcast". Elle
ne cherche pas les notes : elle cherche l'accroche culturelle.

**Ses 3 besoins clés :**
1. Tag curriculum visible en premier plan sur chaque recommandation
2. Badge source éditoriale (ARTE, Lumni, France Culture) = signal de confiance
3. Passerelle Accueil → Découvrir : elle ne navigue pas spontanément jusqu'au 4e onglet

---

## Sprint A — Consensus, faible effort, impact multi-personas
> ~1-2 jours. Corrections immédiates visibles à l'ouverture.

### A1. GlobalStatusBanner remonte en tête de scroll
**Fichier** : `Noto/Views/Home/HomeView.swift`
- Déplacer `GlobalStatusBanner` avant `StoryRingsRow` dans le `LazyVStack`
- Augmenter l'opacité de fond : `success.opacity(0.08)` → `0.18`, idem `warning.opacity(0.1)` → `0.18`
- Personas : Nathalie (H), Sophie M. (H)

### A2. Badge carnets non signés sur tab Actualités
**Fichier** : `Noto/Views/MainTabView.swift`
- Ajouter `unsignedCarnetsCount` au badge de l'onglet Actualités (en plus de `unreadMessagesBadge`)
- `badge(unreadMessagesBadge + unsignedCarnetsCount)`
- Personas : Nathalie (H), Sophie M. (M)

### A3. Tag curriculum en position #2 sur RecoRow
**Fichier** : `Noto/Views/Discover/DiscoverView.swift` — `RecoRow`
- Déplacer le bloc `gradeTags` HStack immédiatement après le titre (`Text(reco.title)`)
- Retirer le bloc `linkedChildName` du bas et le fusionner dans le tag : `"Histoire · 3e · Pour Sophie"`
- Personas : Sophie C. (H)

### A4. Source éditoriale badge sur RecoRow
**Fichier** : `Noto/Views/Discover/DiscoverView.swift` — `RecoRow`
- Si `reco.source` (champ Celyn) est non vide, afficher badge gris clair à côté du `typeLabel`
- Fallback : si champ absent de l'API, ajouter `source: String?` à `CultureSearchResult` + déclarer dans le mapping
- Personas : Sophie C. (H)

### A5. Empty states → bouton "Synchroniser maintenant"
**Fichiers** : `SchoolView.swift`, `DiscoverView.swift`, `ActualitesView.swift`
- Sur chaque `ContentUnavailableView` avec "apparaîtra après synchronisation", ajouter un `Button("Synchroniser")` qui poste `NotificationCenter.navigateToHome` ou appelle directement `syncAll()`
- Personas : tous (M)

### A6. HeroCard enrichie quand 0 messages non lus
**Fichier** : `Noto/Views/Home/HomeView.swift` — `HeroCard`
- Dans le `else` (0 messages), afficher sous la date : nombre de devoirs à venir + nombre de notes cette semaine
- Ex. "3 devoirs cette semaine · 2 notes récentes"
- Personas : Nathalie (M), Sophie M. (M)

---

## Sprint B — Valeur élevée par persona
> ~3-4 jours. Fonctionnalités visibles nécessitant une nouvelle vue ou logique.

### B1. FamilySchoolView — résumé consolidé (dette UX)
**Fichier** : `Noto/Views/School/SchoolView.swift` — `FamilySchoolView`
- Remplacer le prompt "sélectionnez un enfant" par une liste de `ChildSchoolCard` (déjà implémentée !)
- `ChildSchoolCard` affiche : prénom, établissement, pending homework count, unread messages
- Ajouter un tap sur la carte qui sélectionne l'enfant via un callback
- Personas : Sophie M. (H)

### B2. Carte "Découvrir" sur Accueil (bridge vers tab 4)
**Fichier** : `Noto/Views/Home/HomeView.swift`
- Si `recos` disponibles (requiert bridge avec DiscoverView ou cache `@AppStorage`), afficher une carte BriefingCard-style :
  - Titre : "Pour [Prénom] · [matière en cours]"
  - Sous-titre : premier résultat Celyn (titre + tag curriculum)
  - CTA : "Voir tout dans Découvrir →" → post `NotificationCenter.navigateToDiscover`
- Personas : Sophie C. (H), Sophie M. (M)

### B3. ChildStoryRing tap → sheet récap enfant
**Fichier** : `Noto/Views/Home/HomeView.swift` — `ChildStoryRing`
- Remplacer `Button(action: {})` par une sheet `ChildQuickView`
- `ChildQuickView` : notes récentes (3 dernières), prochain devoir, carnet à signer, badge école
- Personas : Nathalie (H), Sophie M. (M)

### B4. Notifications : catégorie "carnet à signer"
**Fichier** : `Noto/Services/NotificationService.swift` (à créer ou étendre)
- Ajouter déclencheur : quand un `Message.kind == .schoolbook && !msg.read` est inséré en sync
- Notification : "Carnet de liaison — [Prénom]" avec body = sujet du mot
- Personas : Nathalie (H)

### B5. Child Selector Bar — meilleure affordance + tooltip premier lancement
**Fichier** : `Noto/Views/Components/ChildSelectorBar.swift`
- Ajouter un label "Afficher :" à gauche du sélecteur, ou indicateur "Tous ✓" quand aucun enfant sélectionné
- Tooltip premier lancement : `@AppStorage("hasSeenChildSelectorTip")` — afficher un callout SwiftUI `.popoverTip` (iOS 17 TipKit) ou un overlay custom pointant vers la barre
- Personas : tous (M)

---

## Sprint C — Structurel / données-dépendant
> ~1 semaine. Vues composites, intégrations système, données nouvelles.

### C1. "Semaine en un coup d'œil" — vue composite EDT × Devoirs
**Fichier** : nouveau `Noto/Views/Home/WeekOverviewView.swift`
- Accessible depuis Accueil via un bouton "Cette semaine →" ou comme section du briefing le dimanche soir (détectable via `Calendar.current.component(.weekday, from: .now) == 1`)
- Affiche : jours de la semaine en horizontal, pour chaque jour : matières + devoirs dus
- Regroupement multi-enfants possible
- Personas : Sophie M. (H)

### C2. Photos — raccourci sur Accueil
**Fichier** : `Noto/Views/Home/HomeView.swift`
- Si `child.photos.count > 0`, afficher une carte "Dernières photos · [Prénom]" avec une grille 3×1 de thumbnails (ShimmerView pendant le chargement)
- Tap → ouvre `PhotoGridView` en sheet
- Personas : tous (M)

### C3. GradeRow — contexte de classe
**Fichier** : `Noto/Views/School/SchoolView.swift` — `GradeRow`
- Si `grade.classAverage` disponible (champ optionnel à ajouter sur le modèle `Grade`), afficher "moy. X.X" en gris clair sous la note
- Conditionner la couleur danger/warning sur l'écart à la moyenne plutôt que sur la valeur absolue
- Note : donnée non disponible sur tous les établissements — affichage conditionnel
- Personas : Nathalie (H)

### C4. RecoDetailView — "Ajouter à mon agenda"
**Fichier** : `Noto/Views/Discover/RecoDetailView.swift`
- Pour les `reco.type == "event"` avec une date, ajouter un bouton "Ajouter à l'agenda" via `EventKit`
- Demander autorisation `EKEventStore` au tap (ne pas demander à froid)
- Personas : Sophie C. (H)

### C5. Notifications intelligentes configurables
**Fichier** : `Noto/Views/Settings/SettingsView.swift` + `NotificationService`
- Ajouter section "Alertes" dans Réglages avec seuils par enfant :
  - Note sous X/20 (slider 0-12, défaut 10)
  - Absence non justifiée : toggle
  - Carnet à signer : toggle (déjà en B4)
  - Recommandation culturelle hebdo : toggle
- Personas : Nathalie (H), Sophie M. (H)

---

## Récapitulatif Fichiers Touchés

| Fichier | Sprints |
|---|---|
| `Home/HomeView.swift` | A1, A6, B2, B3, C2 |
| `MainTabView.swift` | A2 |
| `Discover/DiscoverView.swift` | A3, A4 |
| `School/SchoolView.swift` | A5, B1, C3 |
| `Components/ChildSelectorBar.swift` | B5 |
| `Discover/RecoDetailView.swift` | C4 |
| `Settings/SettingsView.swift` | C5 |
| `Services/NotificationService.swift` | B4, C5 |
| nouveau `Home/WeekOverviewView.swift` | C1 |

---

## Décisions Techniques à Valider

- **Source éditoriale Celyn** : vérifier que `CultureSearchResult` expose un champ `source: String?` — si non, l'ajouter dans `CultureAPIClient` mapping.
- **Cache recos pour bridge Accueil→Découvrir** : `DiscoverView` charge les recos à la demande. Pour B2, soit passer les recos via `@AppStorage` JSON (simple), soit créer un `CultureRecoCache` singleton partagé.
- **TipKit vs overlay custom pour B5** : TipKit (iOS 17) est disponible dans la target. Préférer TipKit pour la gestion automatique de la fréquence d'affichage.
- **EventKit pour C4** : ajouter `NSCalendarsUsageDescription` dans `Info.plist`.
