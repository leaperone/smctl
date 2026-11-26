# Pulse : feuille de route

Pulse est une app de barre des menus et un CLI (`pulse`) pour surveiller les températures et piloter les ventilateurs des Mac Apple Silicon. Elle est construite sur [smctl](https://github.com/leaperone/smctl).

## 1. Organisation du code

| Couche | Contenu | Règle |
|---|---|---|
| **smctl d'origine** | SMCCore, PolicyEngine, daemon, CLI, batterie, écran, alertes | On l'étend sans rien supprimer. Les mises à jour arrivent par `git merge upstream/main` |
| **Extensions génériques** | Courbes en %, formes de courbe, motifs de capteurs, EMA, zone morte d'écriture | Commits isolés et testés, qu'on peut proposer en PR à smctl |
| **Pulse uniquement** | App de barre des menus, éditeur, `pulse status`, packaging | Nouveaux dossiers et modules |

Tous les noms et identifiants (CLI, daemon, XPC, chemins, logs) sont regroupés dans `Sources/ProductIdentity/ProductIdentity.swift`.

## 2. Choix techniques

### 2.1 Profils : on étend le TOML existant
Les nouveaux champs vont dans les `[[fan.curves]]` de `/etc/pulse/config.toml`. L'app les modifie via XPC ; le daemon les valide et les sauvegarde. Ce choix garde une seule source de vérité, modifiable en SSH et versionnable dans des dotfiles. Les anciennes configs smctl restent compatibles. Le sérialiseur TOML écrit à la main (`writeConfig`) est couvert par des tests aller-retour.

### 2.2 Courbes en pourcentage
- Une valeur de point peut être `"40%"`, en plus des RPM (`1600`) et de `"max"`.
- 0 % correspond à `F0Mn` et 100 % à `F0Mx`, pour chaque ventilateur.
- L'interface affiche des % ou des RPM, au choix.

### 2.3 Formes prédéfinies compilées en points
Chaque forme est une fonction normalisée f : [0,1] → [0,1], croissante, avec f(0)=0 et f(1)=1. Ses paramètres :
- `start` / `end` (°C) : étirer ou raccourcir la rampe ;
- `min` / `max` (%) : plancher et plafond ;
- `steepness` : raideur, pour les formes qui en ont une.

| Forme | Comportement |
|---|---|
| `linear` | Rampe régulière |
| `sigmoid` | Calme, puis montée franche au milieu |
| `exponential` | Reste bas longtemps, puis accélère |
| `logarithmic` | Réagit tôt, puis plafonne |
| `steps` | Paliers |
| `points` | Points libres ; n'importe quelle forme se convertit en points |

Le daemon compile la forme en environ 32 points, puis réutilise sans modification le `FanCurveEngine` de smctl (interpolation, hystérésis, vitesse de variation).

```toml
[[fan.curves]]
name = "balanced"
sensors = ["Tp*"]
shape = { type = "sigmoid", start = 70, end = 100, min = "0%", max = "100%", steepness = 6 }
hysteresis = 3
slew_rate = "8%"        # par seconde, en montée
fall_slew_rate = "3%"   # par seconde, en descente
```

### 2.4 Capteurs
On accepte des motifs (`"Tp*"` pour les hotspots CPU, `"Tg*"` pour le GPU, `"Ts*"` pour le boîtier) en plus des clés exactes. L'interface les affiche sous des noms lisibles. L'agrégation par défaut est le maximum, avec une moyenne pondérée optionnelle.

### 2.5 Lissage et efficacité
- L'hystérésis et les vitesses de variation de smctl sont conservées ; l'interface les exprime en %/s.
- EMA optionnel (`smoothing`, en secondes). On ne l'active par défaut qu'après des mesures sur une vraie machine.
- Zone morte d'écriture : on n'écrit plus dans le SMC que si l'écart dépasse environ 1 % ou 50 RPM, ou si macOS a repris le contrôle.

### 2.6 Presets
« Auto système », plus « Silencieux », « Équilibré », « Performance » et « Maximum », intégrés et non modifiables. Chacun propose une action « Dupliquer ». `quiet` et `full` (smctl) restent disponibles. Les noms réservés sont protégés par la validation.

### 2.7 Communication app ↔ daemon
- Nouvelles méthodes XPC : `getTelemetry` (instantané en cache, un seul appel), `listFanCurves`, `upsertFanCurve`, `deleteFanCurve`, `previewFanCurve`.
- Le daemon lit les capteurs toutes les `[fan] interval` secondes (1 à 5, 2 par défaut, réglable par un slider dans l'app et par `pulse fan interval`), avec un rythme optionnel sur batterie (`battery_interval`) que le daemon applique seul au branchement ou débranchement, et chaque seconde près du plafond du garde-fou. L'app l'interroge au même rythme. On n'utilise pas de push XPC : la complexité n'en vaut pas la peine.
- Sans daemon, l'app lit les capteurs directement via SMCCore, en mode surveillance seule.

### 2.8 CLI `pulse`
- Tout l'existant de smctl est conservé.
- `pulse status` : vue d'ensemble pour le SSH.
- `pulse fan curve list|show|set|delete|preview` : gestion des courbes.
- `--json` est disponible partout.

### 2.9 App
- **Interface** : SwiftUI, `MenuBarExtra(.window)`, Observation. L'éditeur utilise Swift Charts.
- **Cible** : macOS 26 ou plus pour l'app ; le package reste en macOS 14.
- **Projet** : package SwiftPM séparé dans `App/` (macOS 26), qui dépend du package principal. `App/Package.swift` s'ouvre dans Xcode ; `scripts/build-app.sh` assemble `dist/Pulse.app`. Pas de XcodeGen.
- **Barre des menus** : `NSStatusItem` + `NSPopover` en AppKit, avec les vues en SwiftUI. `MenuBarExtra` redessinait l'élément à chaque mise à jour de la scène (environ 3,6 % de CPU au repos).
- **Packaging** : `pulse` et `pulsed` sont embarqués dans `Contents/Helpers/`. L'installation du service passe par `pulse daemon install` avec les droits administrateur. Lancement à l'ouverture de session via `SMAppService.mainApp`, et `LSUIElement` pour ne pas apparaître dans le Dock.
- **Signature** : ad hoc pour un usage perso. Les écritures sont autorisées aux comptes admin (vérifié sous macOS 27.2).

### 2.10 Conflits
On détecte les autres contrôleurs de ventilateurs (daemon smctl, TG Pro, Macs Fan Control). On affiche un avertissement, sans rien désinstaller automatiquement.

## 3. Phases

Le déroulé détaillé de chaque étape restante, réévalué entre deux étapes, est dans [PLAN.md](PLAN.md).

- [x] **Phase 0, fondations** : fork, build, tests, daemon ad hoc sous macOS 27.2, écriture sur le ventilateur vérifiée, licence MIT, centralisation des identifiants
- [x] **Phase 1a, moteur** : conversion % → RPM (`FanSpeedRange`), `FanCurveShape` (compilation adaptative), motifs de capteurs, EMA
- [x] **Phase 1b, daemon** : config TOML étendue, presets, zone morte d'écriture, XPC (`getTelemetry`, CRUD des courbes ; l’aperçu est calculé côté client avec PolicyEngine)
- [x] **Phase 1c, CLI** : `pulse status`, `pulse fan curve …`, détection des conflits
- [x] **Phase 2, app de barre des menus** : package `App/`, libellé, popover, sélecteur de profil, installation du service, réglages, option monochrome pour la barre des menus (au repos : environ 0,2 % de CPU, 19 Mo)
- [x] **Phase 3, éditeur** : onglet Courbes, graphique interactif (formes, poignées, raideur, points), aperçu live, bascule %/RPM, réglages d'entrée et de réponse, annuler/rétablir, protection des modifications non enregistrées (au repos : environ 0,1 % de CPU, 18 Mo ; détail dans [PLAN.md](PLAN.md))
- [ ] **Phase 4, finitions** (détail et état dans [PLAN.md](PLAN.md)) :
  - [x] 4a : notification quand le garde-fou se déclenche et quand il se relâche
  - [x] 4b : lancement au login (le test après redémarrage est rattaché à la 4e)
  - [x] 4c : déclencheurs selon l'état du système (app ou jeu ouvert, mode économie d'énergie, batterie ou secteur)
  - [x] 4d : validation sur MacBook Pro M1 Pro, `pulse doctor`, interface pour les Mac sans ventilateur et à deux ventilateurs
  - [ ] 4e : campagne de tests matériels, sur le MacBook et le Mac mini
  - [ ] 4f : 1.0 — fait : profilage, intervalle de collecte de 1 à 5 s (avec un rythme sur batterie), fenêtre gardée au premier plan après le mot de passe, CI pour `App/`, aide utilisateur (`docs/HELP.md`, ouverte depuis le popover) ; reste : publication (après la 4e)

## 4. Tests

### Tests unitaires (XCTest, en CI)
- **Formes** : f(start)=min et f(end)=max, croissance monotone, valeurs dans [min, max], plat hors de la rampe, effet de la raideur, rejet des paramètres invalides.
- **% → RPM** : plusieurs plages et plusieurs ventilateurs, jamais sous `F0Mn`.
- **Config** :
  - aller-retour TOML ;
  - une ancienne config smctl se lit à l'identique ;
  - erreur explicite sans réinitialisation de la config ;
  - noms réservés protégés.
- **Capteurs** : motifs, mélange de motifs et de clés exactes, aucun capteur correspondant.
- **EMA et zone morte** : réponse à un échelon, pas d'écriture sous le seuil, réécriture si le mode a été repris.
- **Daemon** (avec le faux backend SMC) :
  - ajout de courbe, activation, persistance ;
  - suppression du profil actif, qui repasse en auto ;
  - déclenchement du garde-fou ;
  - preview sans effet de bord.
- **Protocole** : encodage et décodage des DTO, compatibilité entre un ancien client et un nouveau daemon.

### Simulation sur traces réelles
On rejoue des traces enregistrées (repos, compilation, pics) avec chaque preset. On vérifie un nombre borné de changements de sens, le respect de la vitesse de variation, le temps de réaction à un échelon, et qu'aucune cible ne descend sous le plancher.

### Tests matériels (mini, puis MacBook)
1. Installation et désinstallation.
2. Changement de profil depuis l'app et en SSH.
3. Veille et réveil.
4. `kill -9 pulsed`.
5. Fermeture de l'app.
6. Charge soutenue.
7. Garde-fou provoqué.
8. Outil concurrent lancé.
9. Redémarrage du Mac.

### Performance
- **Objectifs** : app au repos sous 0,1 % de CPU et sous 30 Mo de mémoire ; `pulsed` sous 0,2 % de CPU ; tick sous 50 ms hors écriture.
- **Mesure** : avant et après la zone morte d'écriture.
- **Résultats (MacBook Pro M1 Pro, 26/11/2026)** : app au repos à 0,15 % de CPU et 20 Mo réels ; daemon avec une courbe active à 0,62 % (1 s), 0,30 % (2 s, défaut) et 0,14 % (5 s). En profil auto, le daemon ne lit les capteurs qu'à la demande de l'app. Détail dans [PLAN.md](PLAN.md).

## 5. Risques

| Risque | Parade |
|---|---|
| Une mise à jour de macOS modifie le SMC | Dégradation en lecture seule, suivi d'upstream |
| Le sérialiseur TOML casse la config | Tests aller-retour, écriture atomique |
| Conflits de merge dans `Daemon.swift` | Ajouts regroupés dans des extensions de fichiers séparés |
| Chemin `Ftst` (MacBook M3/M4) non validé | Le MacBook Pro M1 Pro n'a pas de `Ftst` (chemin direct, validé). `pulse doctor --test-fans` permettra de valider `Ftst` sur un M3/M4 |
| Signature ad hoc refusée par un futur macOS | Passage à un compte développeur |
