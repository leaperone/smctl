# Pulse : plan détaillé des étapes restantes

Ce document complète la [feuille de route](ROADMAP.md). Il précise comment chaque étape sera menée. **On le réévalue entre deux étapes** : on y note ce qui a été appris et les problèmes rencontrés, puis on ajuste les étapes suivantes (section « Journal de réévaluation » en bas).

Ordre : **A** (vrai fork GitHub), puis **3a → 3f** (éditeur), puis **4a → 4f** (finitions).

Chaque étape se clôt de la même façon (« porte de validation ») :
1. `swift build` et `swift test`, pour le package principal et pour `App/` ;
2. `swift run -c release --package-path App PulseBench 20` : aucune phase « fermée » au-dessus de 1 % de CPU ;
3. mesure réelle de l'app (20 s d'attente, puis 60 s avec `ps -o time=`) et du daemon ;
4. captures `PulseSnapshots` relues, en clair et en sombre ;
5. commit isolé et poussé, case cochée dans la feuille de route, entrée ajoutée au journal ci-dessous.

---

## Référence de performance (26/11/2026, build 95, Mac mini M4, macOS 27.2)

| Mesure | Résultat | Objectif |
|---|---|---|
| App au repos, battement désactivé | **0,13 %** de CPU, 20 Mo (après 3a : **0,07 %**, 17 Mo) | < 0,1 %, < 30 Mo |
| App au repos, battement « toujours » | 2,1 % de CPU | coût connu et documenté |
| `pulsed` | 0,22 % de CPU, 18 Mo | < 0,2 % |
| PulseBench, au repos | 0,6 % (données d'exemple très variables) | – |
| PulseBench, popover ouvert | 2,9 % (sondage chaque seconde, graphique) | acceptable quand visible |
| PulseBench, réglages ouverts | 2,6 % (aperçu qui bat) | acceptable quand visible |
| PulseBench, popover ou réglages refermés | **0,5–1 %** (avant correctifs : 3,5 % et **11 %**) | ≈ repos |
| Mémoire après ouverture des vues | ~50–70 Mo (SwiftUI et Charts restent chargés) | à surveiller |
| Glisser une poignée (60 Hz, rendu forcé) | 12 ms de CPU par image, ~38 % pendant le geste | fluide sur M4 ; à vérifier sur MacBook |

Le correctif `656b888` a supprimé une fuite : les vues fermées continuaient d'être rendues. Après 7 h 30, l'app consommait 16 % de CPU et 150 Mo. **Leçon pour la suite** : toute nouvelle fenêtre (l'éditeur en particulier) est construite à l'ouverture et libérée à la fermeture. Chaque nouvelle vue ajoute sa phase dans PulseBench.

Deux pistes, sans urgence : `pulsed` est à 0,22 % pour un objectif de 0,2 % (à profiler en 4f) ; le popover ouvert sonde chaque seconde (on pourrait passer à 2 s si le graphique reste fluide).

---

## Étape A : faire de `fstormacq/pulse` un vrai fork de `leaperone/smctl`

> ✅ **Faite le 26/11/2026.** Il ne reste que l'étape 8 : supprimer `pulse-archive` après ta vérification.

**Constat.** Le dépôt GitHub est privé et n'est pas un fork. L'historique git est pourtant correct : `main` contient tout `upstream/main`, avec 35 commits d'avance et 0 de retard. GitHub ne permet pas de transformer un dépôt existant en fork, et un fork d'un dépôt public est forcément public.

**Pré-vérifications (déjà faites) :**
- aucun secret dans les fichiers suivis : le DSN Sentry ne sert que dans des tests, avec `example.invalid` ;
- aucune issue, PR, release ni secret GitHub sur le dépôt actuel : rien à migrer ;
- le fichier non suivi « Apps Swift contrôle ventilateurs Mac.md » reste local ;
- les tags `v0.2.0`…`v0.2.4` sont ceux d'upstream et existeront déjà dans le fork ;
- **point de confidentialité** : 32 des 35 commits Pulse portent l'adresse e-mail iCloud personnelle. Un fork public la rendrait visible.

**Déroulé :**
1. **Décision e-mail** (à prendre par toi). L'option recommandée réécrit l'auteur des commits Pulse uniquement (`git filter-repo --mailmap`) vers `126812667+fstormacq@users.noreply.github.com`. Les commits d'upstream restent intacts, donc l'ascendance avec smctl est conservée. Seuls les hashs des 35 commits Pulse changent, et personne d'autre n'en dépend. Avant la réécriture, on pose un tag local `backup/pre-fork`. On règle ensuite `git config user.email` sur l'adresse noreply et tu peux activer « Block command line pushes that expose my email » dans les réglages GitHub.
2. `gh repo rename pulse-archive -R fstormacq/pulse` : l'ancien dépôt reste privé et sert de filet de sécurité.
3. `gh repo fork leaperone/smctl --fork-name pulse --clone=false`, puis vérifier `isFork: true` et `parent: leaperone/smctl`.
4. `git remote set-url origin git@github.com:fstormacq/pulse.git`, puis `git push origin main`. C'est une avance rapide : notre `main` descend de `upstream/main`.
5. Réglages du fork : description, sujets (`macos`, `fan-control`, `apple-silicon`, `menu-bar`), Issues activées. Les Actions sont désactivées par défaut sur un fork : on les active pour le CI existant (`ci.yml` ne compile que le package principal, sans secrets).
6. Vérifications : le badge « forked from leaperone/smctl » apparaît ; `gh repo view` répond correctement ; un clone frais compile ; le CI passe ; `git fetch upstream && git merge upstream/main` indique « Already up to date ».
7. Mettre à jour la mémoire du projet et le README (liens, mention du fork).
8. **Suppression de `pulse-archive`** : seulement après ta vérification, avec ta confirmation explicite. Sinon on la garde privée.

**Risques :** le fork prend le nom `pulse` seulement si l'ancien dépôt a bien été renommé avant (étape 2). En cas d'échec, l'archive est intacte et rien n'est perdu. Le dépôt devient public, ce qui est assumé avec la licence MIT.

---

## Phase 3 : éditeur de courbes

**But :** créer, dupliquer et ajuster une courbe à la souris, avec un aperçu immédiat, sans jamais écrire une config invalide.

**Principes retenus :**
- L'éditeur vit dans un nouvel onglet **« Courbes »** des Réglages (agrandi pour cet onglet), comme les réglages des apps Apple. Le popover gagne « Modifier… » et « Nouvelle courbe… », qui ouvrent cet onglet.
- Le modèle d'édition (`CurveDraft`) est de la logique pure, sans SwiftUI, pour pouvoir le tester entièrement.
- Le calcul passe par la même fonction que le daemon (`FanCurveSpec.resolve`). Ce qui est affiché est donc ce qui sera appliqué.
- La fenêtre est construite à l'ouverture et libérée à la fermeture (leçon de ce jour).

### 3a. Onglet « Courbes » et navigation

> ✅ **Faite le 26/11/2026** (voir le journal).
- `SettingsPane.curves`, avec des tailles par onglet. L'onglet Courbes est plus grand (environ 760 × 560) ; la taille de la fenêtre suit l'onglet avec une animation.
- Colonne gauche : liste des profils. Les presets (Silencieux, Équilibré, Performance, cadenas) sont en lecture seule et proposent « Dupliquer ». Les courbes perso permettent renommer, dupliquer et supprimer, avec confirmation. Les courbes invalides lues dans la config sont signalées avec leur message d'erreur.
- `SettingsWindowController.show(pane:selecting:)` est appelé depuis le popover.
- Tests : navigation (le bon onglet et la bonne courbe sont sélectionnés), suppression du profil actif (retour à auto, déjà géré par le daemon).
- PulseBench : ajout des phases « onglet Courbes ouvert » et « refermé ».

### 3b. Modèle `CurveDraft` (logique, sans interface)

> ✅ **Faite le 26/11/2026** (voir le journal).
- L'état comprend la spec en cours, la spec d'origine, `isDirty`, l'erreur de validation et un nom technique dérivé du libellé (`Night mode` → `night-mode`, unique, jamais un nom réservé).
- Opérations :
  - changer de forme, en gardant start, end, min et max ;
  - déplacer la poignée basse (start, min) ou haute (end, max), avec des contraintes : start < end − 2 °C, min ≤ max, 0–100 %, températures bornées à 30–110 °C ;
  - régler la raideur (0–30) ou le nombre de paliers (1–20) ;
  - **convertir en points**, à environ 8–12 points choisis là où la courbe varie le plus, pour pouvoir les déplacer à la main ;
  - en mode points : ajouter, déplacer (les températures restent strictement croissantes) et supprimer, avec au moins 2 points ;
  - paramètres avancés : capteurs (groupes CPU `Tp*`, GPU `Tg*`, boîtier `Ts*`), agrégation (max ou moyenne), hystérésis, montée et descente en %/s, lissage en secondes.
- Annuler et rétablir via `UndoManager`, en regroupant les déplacements d'un même glisser.
- Tests : contraintes de chaque poignée, conversion en points (écart avec la forme d'origine inférieur à 2 % sur toute la plage), mode points toujours valide, `validate()` qui ne lève jamais d'erreur sur un brouillon accepté, aller-retour avec `SampleService`.

### 3c. Graphique interactif

> ✅ **Faite le 26/11/2026** (voir le journal).
- On part de `CurvesChart`. `chartOverlay` et `ChartProxy` convertissent les coordonnées en (°C, %) ; `DragGesture` pilote les poignées (`PointMark` agrandis au survol, curseur adapté).
- Forme : 2 poignées d'extrémité, plus une poignée de raideur au milieu de la rampe qu'on glisse verticalement (avec un curseur en complément, pour l'accessibilité).
- Paliers : un réglage du nombre de paliers. Points : on glisse chaque point, un double-clic en ajoute un, la touche Suppr retire le point sélectionné.
- **Bascule %/RPM** pour l'axe Y, à partir de la plage F0Mn/F0Mx lue dans la télémétrie. Sans ventilateur, seul le % est proposé.
- VoiceOver : chaque poignée est un élément ajustable (incrément d'1 °C ou d'1 %).
- Performance : pendant un glisser, on recalcule environ 140 points par image. Si ce n'est pas fluide, on réduit la résolution pendant le glisser.

### 3d. Aperçu live

> ✅ **Faite le 26/11/2026** (voir le journal). « Essayer 60 s » : abandonné à la revue.
- Une ligne verticale indique la température lissée actuelle, avec un point sur la courbe : « 54 °C → 12 % (1 450 RPM) ». On ajoute aussi la vitesse réelle du ventilateur.
- Les presets apparaissent en courbes « fantômes » pâles, pour se repérer.
- Un panneau de réponse indique le temps pour passer du minimum au maximum avec les vitesses de montée choisies, et l'effet de l'hystérésis.
- Option à décider à cette étape : **« Essayer 60 s »**, qui active le brouillon temporairement puis revient au profil précédent. Il faut un petit ajout au daemon (activation temporaire avec retour automatique, garde-fou toujours actif). Sinon, on se contente d'« Enregistrer » et « Enregistrer et activer ».

### 3e. Enregistrement et robustesse

> ✅ **Faite le 26/11/2026** (voir le journal).
- « Enregistrer », « Enregistrer et activer », « Annuler les modifications ». À la fermeture ou au changement de courbe avec des modifications en cours : proposer d'enregistrer, d'ignorer ou d'annuler.
- Les erreurs du daemon (validation, daemon absent) s'affichent dans l'éditeur, et le brouillon est conservé.
- Si la config change ailleurs pendant l'édition (SSH, `pulse fan curve set`) : avertissement « modifiée ailleurs », avec rechargement ou écrasement.
- C'est l'occasion de traiter la raideur du preset Performance : en dupliquant le preset, on obtient une version plus douce entre 60 et 63 °C. On ne change pas le preset sans ton accord.

### 3f. Validation de la phase 3

> ✅ **Faite le 26/11/2026** (voir le journal). **La phase 3 est terminée et attend ta revue.**
- Captures de l'éditeur dans chaque mode (forme, paliers, points), en clair et en sombre.
- PulseBench : éditeur ouvert, éditeur refermé, plus un glisser simulé.
- Test réel : créer « night » dans l'app, l'activer, vérifier avec `pulse status` et `pulse fan curve show night` (en SSH), modifier en SSH et voir l'app se mettre à jour, puis supprimer.
- Mise à jour du README (capture de l'éditeur) et de la feuille de route.

---

## Phase 4 : finitions

### 4a. Notification du garde-fou

> ✅ **Faite le 26/11/2026** (`03ac2d5`, voir le journal). Il reste à la vérifier sur le vrai matériel avec `sudo scripts/test-safety-notification.sh`.
- Dans l'app : une notification (`UserNotifications`) quand `safety.latched` passe de faux à vrai (« Ventilateur au maximum : X °C sur Tp0E »), puis une autre au retour à la normale. Un réglage permet de les couper.
- Risque : les notifications avec une signature ad hoc. À tester dès le début de l'étape. Plan B : une alerte dans le popover et l'icône d'avertissement, qui existent déjà.
- Tests : transitions (une seule notification par événement, aucune au lancement si le garde-fou est déjà engagé).

### 4b. Lancement au login (déjà livré en phase 2)
- Il ne reste qu'à vérifier après un vrai redémarrage (test matériel 9) que l'app et le daemon reviennent et que le profil actif est conservé.

### 4c. Déclencheurs selon l'état du système (révisé le 26/11/2026)

> ✅ **Faite le 26/11/2026** (`03d496d`, voir le journal). Concentration reste en option, non développée.

**Ta décision :** pas d'horaires fixes dans le daemon. Le profil suit ce que fait le Mac : un mode Concentration actif, Night Shift, un jeu, la charge, l'économie d'énergie…

**Ce que macOS permet de lire** (testé sur le Mac mini) :

| Signal | Comment | Statut |
|---|---|---|
| Économie d'énergie | `ProcessInfo.isLowPowerModeEnabled` et sa notification | API publique |
| Secteur, batterie, en charge | `IOPSCopyPowerSourcesInfo`, notification `IOPSNotificationCreateRunLoopSource` | API publique (MacBook surtout) |
| Mode Concentration actif, **et lequel** | `~/Library/DoNotDisturb/DB/Assertions.json` et `ModeConfigurations.json` (noms : « Repos », « Jeu vidéo », « Work »…) | Lisible ; **probablement soumis à l'accès complet au disque** (à vérifier depuis l'app) |
| Night Shift | `CBBlueLightClient` (CoreBrightness, **API privée**) | Lisible depuis le terminal ; le sens des champs reste à confirmer |
| Mode Jeu de macOS | aucune API ; macOS l'active quand un jeu (`LSApplicationCategoryType` = jeux) est **en plein écran au premier plan**, et on peut détecter la même chose | Heuristique |
| Écran éteint, session verrouillée | notifications `NSWorkspace` / distribuées | API publique |

**Priorités décidées avec toi (26/11/2026) :**
1. **Mode Jeu** → Performance ou une courbe « gaming ». C'est ce qui t'intéresse le plus. Piste trouvée dans `gamepolicyd` : des notifications Darwin (`com.apple.gamepolicy.game-mode-session`, `fullscreenStateChanged`, `GameExited`) et un service `scdynamicstore`. **À confirmer** avec `scripts/gamemode-probe.sh` pendant une vraie partie. Si rien d'exploitable n'en sort, on se rabat sur la même heuristique que macOS (un jeu en plein écran au premier plan).
2. **Économie d'énergie**, **secteur / batterie**.
3. **Concentration** (« Repos » en particulier) : en option. Ce sera « à voir » quand le reste marchera, de peur que ce soit un gadget.
4. **Night Shift : abandonné** (tu entendais « Repos » ; on évite ainsi l'API privée).

**Conception :**
- **Les règles vivent dans l'app**, pas dans le daemon. Ces signaux appartiennent à la session de l'utilisateur, que le daemon (root) ne voit pas. Conséquence : elles ne s'appliquent que si l'app tourne (elle démarre au login). Le profil choisi reste visible en SSH (`pulse status`).
- **Une règle** : « Quand ‹condition›, utiliser ‹profil› ». Les règles sont ordonnées, et la première qui correspond l'emporte. Si aucune ne correspond, on revient au **profil de base**, c'est-à-dire le dernier profil choisi à la main.
- **Choix manuel pendant qu'une règle est active** : il devient le nouveau profil de base, et la règle est suspendue jusqu'à ce que sa condition disparaisse puis revienne. Pulse ne reprend donc jamais un choix que tu viens de faire.
- **Garde-fou** (ta décision 3) : après un déclenchement, **les règles sont suspendues** jusqu'à ce que tu choisisses toi-même un profil. Une règle ne doit pas réactiver une courbe sur un Mac qui a surchauffé.
- **Anti-rebond** : une condition doit tenir quelques secondes avant d'agir (par exemple, une sortie de plein écran rapide ne fait pas basculer le profil).
- **Interface** : une section « Automatic Switching » (liste de règles, ajout, ordre, interrupteur général) dans un nouvel onglet ou sous Curves. Le popover indique « Silent · Focus: Repos » quand une règle est active.

**Découpage :**
1. `SystemConditions` : lecture et observation des signaux, avec un test de faisabilité de chacun **depuis l'app** (accès complet au disque pour Concentration, Night Shift). Les signaux inaccessibles sont grisés et expliqués.
2. `AutomationEngine` (logique pure, testée) : règles, priorité, profil de base, suspension manuelle, suspension après le garde-fou, anti-rebond.
3. Branchement sur `PulseStore.activate` et persistance des règles (préférences de l'app).
4. Interface, captures et mesures. Point d'attention : les observations ne doivent rien coûter au repos (notifications plutôt que sondage ; le fichier Concentration surveillé avec `DispatchSource`).
5. Test réel : activer « Repos », vérifier la bascule, puis faire un choix manuel et vérifier qu'il est respecté.

**Risque :** l'accès complet au disque est accordé à une signature précise. Avec une signature ad hoc, chaque build peut le perdre. Ça gêne le développement, pas l'usage quotidien. Si Concentration reste inaccessible, on garde les autres signaux et on documente.

### 4d. Validation sur MacBook (nécessite ton MacBook)

> ✅ **Terminée le 26/11/2026** sur MacBook Pro M1 Pro (voir le journal).
- Chemin `Ftst` (les MacBook Pro M-series ont besoin du déblocage d'écriture), fonctions batterie de smctl, modèle sans ventilateur (MacBook Air : surveillance seule, éléments liés au ventilateur masqués).
- Commande de diagnostic `pulse doctor` à créer : elle produira un rapport à me transmettre.

### 4e. Campagne de tests matériels (§4 de la feuille de route)

> ✅ **Terminée le 27/11/2026** : campagne réussie sur le MacBook Pro M1 Pro, puis sur le Mac mini M4 (`scripts/hardware-campaign.sh`, résultats dans `docs/campaign/`).
- Installation et désinstallation, changement de profil (app et SSH), veille et réveil, `kill -9 pulsed`, fermeture de l'app, charge soutenue, garde-fou provoqué, outil concurrent, redémarrage.
- Je prépare un script qui guide chaque test et enregistre les résultats. Les étapes avec `sudo` ou une action physique sont faites par toi.

### 4f. Préparation de la version 1.0

> 🟡 **Partie code terminée le 26/11/2026** : profilage, intervalle de collecte (1 à 5 s, rythme sur batterie), fenêtre gardée au premier plan après le mot de passe, CI pour `App/`, aide utilisateur (`docs/HELP.md`). **Reste la publication**, qui attend la 4e et tes décisions (signature, version 1.0, PR vers smctl, `pulse-archive`).
- Profiler `pulsed` (objectif < 0,2 %) et viser < 0,1 % pour l'app au repos.
- CI : ajout de la compilation et des tests de `App/` si les runners proposent Xcode 26.
- Version 1.0, notes de version, archive de `Pulse.app`. Signature : ad hoc ou compte développeur, à décider.
- PR des améliorations génériques vers smctl (courbes en %, formes, zone morte) : à décider (« on verra »). Le fork rend ces PR triviales.

### 4g. Stress test pour régler les courbes (ta demande)

> ✅ **Terminée le 26/11/2026** (voir le journal). Lancer la charge du test 8 sur une courbe et voir comment elle réagit, pour la régler. Dans l'app, et en CLI pour le SSH.
- **Moteur partagé** (`SMCtlClient/PulseStress.swift`) : charge CPU + GPU dans le processus (arrêtable), relevés toutes les 2 s (CPU et GPU max, entrée et sortie de la courbe, vitesse, puissance, garde-fou), attente que le Mac revienne à sa température de départ, phases charge puis refroidissement, synthèse (CPU stable, vitesse stable et écart, accélération, temps jusqu'à 90 % du pic, retour au repos). Le profil d'avant est restauré à la fin. Tests unitaires de la synthèse.
- **CLI** : `pulse fan stress <profil>… [--load] [--cool] [--settle] [--cpu-only] [--json] [--csv]`, relevés en direct puis tableau comparatif. Remplace le script shell écrit d'abord (jamais commité).
- **App** : bouton « Stress Test » dans Réglages › Courbes. Une feuille avec durée et type de charge, graphique en direct (températures, entrée de la courbe, vitesse), synthèse à la fin, et l'essai précédent de la même courbe en transparence pour comparer après un réglage.

### 4h. Publication de la 1.0.0 (décidé le 27/11/2026)

> 🟡 **Étapes 1 à 7 terminées le 27/11/2026, reste la validation (8)**, qui passe par le merge de `dev` dans `main`. GitHub est configuré : tap public `fstormacq/homebrew-tap`, branche `dev`, merge commits seulement (pas de squash), secret `TAP_TOKEN`, ruleset sur `main`.

**Décisions**
- **Branches** : on travaille sur `dev`, et `main` ne reçoit que des PR depuis `dev`. **Chaque push sur `main` publie une release**, s'il y a au moins un `feat`, `fix` ou `perf` depuis le dernier tag.
- **Version calculée à partir des commits** : `feat` donne une version mineure, `fix` ou `perf` un correctif, `!` ou `BREAKING CHANGE` une version majeure. Les commits `docs`, `ci`, `test` et `chore` seuls ne publient rien. Premier tag : **v1.0.0**. La version n'est jamais commitée : elle vient du tag et elle est injectée au build. Aucun commit sur `main` n'est donc fait par la CI, et le ruleset ne la gêne pas.
- **Signature ad hoc**, sans compte Apple ni notarisation.
- **Distribution** : release GitHub et tap Homebrew, sur le modèle de `sebsto/wispr` (Makefile et tap), mais publiée par la CI.
  - `brew tap fstormacq/tap && brew trust fstormacq/tap` (Homebrew 7 demande de faire confiance aux taps tiers), puis `brew install --cask pulse` (app avec le CLI) ou `brew install pulse-cli` (CLI et daemon seuls).
  - Assets de chaque release : `Pulse-X.Y.Z.zip` et `pulse-cli-X.Y.Z-arm64.tar.gz`, avec leurs sha256.
- **Le daemon suit les mises à jour sans réinstallation manuelle**. Le binaire root reste copié dans `/Library/PrivilegedHelperTools/` : le lancer depuis un dossier modifiable par l'utilisateur permettrait d'obtenir les droits root. Il faut donc une autorisation admin à chaque mise à jour, mais elle est demandée automatiquement :
  - **App** (installée par brew ou à la main) : au lancement, si le `pulsed` embarqué est plus récent que le daemon qui tourne, l'app le réinstalle avec la fenêtre de mot de passe macOS (`ServiceInstaller`) ;
  - **CLI** : la première commande qui trouve un daemon plus ancien que le CLI le met à jour avec `sudo` (demande de mot de passe), puis continue. Hors terminal interactif, ou avec `--json`, il se contente d'avertir.
  - Jamais de retour à une version plus ancienne. La config et le profil sont conservés : la campagne l'a vérifié pour une réinstallation par-dessus.
- **Quarantaine** : le cask la retire (`postflight` avec `xattr -dr com.apple.quarantine`). Homebrew 7 met les casks en quarantaine et n'a plus de `--no-quarantine`. Sans ça, Gatekeeper bloquerait l'app ad hoc au premier lancement et à chaque mise à jour, puisque l'identité ad hoc change à chaque build. Le téléchargement direct garde l'étape « Ouvrir quand même ».

**Étapes**
1. ✅ **Une seule version.** Un fichier généré au build (`PulseVersion.swift`) remplace le `"0.2.4"` écrit en dur dans `SMCtlProtocolInfo`. La même valeur va dans l'`Info.plist` de l'app. Un build local s'appelle `X.Y.Z-dev+<sha>` : il ne propose aucune mise à jour et n'en déclenche aucune. Tests : comparaison de versions, version de développement.
2. ✅ **Makefile** (`build`, `test`, `app`, `package VERSION=…`, `release VERSION=…` pour une release manuelle de secours). La CI appelle `make package`, donc une release se reproduit en local. `scripts/release.sh` (signature Developer ID de leaperone) est supprimé.
3. ✅ **Workflow `release.yml`** : déclenché par un push sur `main`, sur un runner `macos-26`.
   - Calcul de la version, puis `make package`, tag, release GitHub avec des notes groupées (Nouveautés, Corrections).
   - Mise à jour du cask et de la formule dans le tap avec `TAP_TOKEN`.
   - Un `workflow_dispatch` en mode d'essai construit les assets sans rien publier.
   - La CI tourne aussi sur `dev`.
4. ✅ **Tap** :
   - `Casks/pulse.rb` : app, lien `binary` vers `pulse`, `uninstall quit:` puis réouverture, `conflicts_with formula: "pulse-cli"`, `postflight` pour la quarantaine, `caveats` pour la première installation du service ;
   - `Formula/pulse-cli.rb` : binaires prêts, `caveats` avec `sudo pulse daemon install` au premier usage, `test do` sur `--version`.
5. ✅ **Détecter une version plus récente.**
   - Le daemon fait déjà une vérification quotidienne (`latestVersion` dans le ping), et le CLI affiche déjà une note.
   - À ajouter : l'app affiche la nouvelle version dans le popover et dans À propos, avec un lien vers la release. Sans daemon (surveillance seule), elle fait sa propre vérification une fois par jour.
   - La commande proposée dépend du canal : `brew upgrade --cask pulse`, `brew upgrade pulse-cli`, ou un lien de téléchargement. Elle remplace `upgradeCommand` (`git pull && swift build`).
6. ✅ **Mise à jour automatique du daemon**, pour l'app et pour le CLI, comme décrit plus haut. Tests : décision « mettre à jour, avertir ou ne rien faire » selon les versions, le terminal interactif et les builds de développement.
7. ✅ **Documentation** : section d'installation du README (brew, téléchargement direct et « Ouvrir quand même », mise à jour), section « Mises à jour » de `HELP.md`, feuille de route.
8. **Validation** :
   - essai du workflow sans publication ;
   - merge `dev` → `main`, qui publie la **v1.0.0** ;
   - installation par le cask sur le MacBook et par la formule sur le Mac mini ;
   - puis un correctif 1.0.1, pour vérifier la détection, `brew upgrade` et la mise à jour automatique du daemon (app et CLI).

Sans lien avec la publication, toujours à décider : la PR vers smctl et la suppression de `pulse-archive`.

---

## Journal de réévaluation

### 26/11/2026 : avant l'étape A
- Option monochrome livrée (`f48c01a`).
- Dernier test de performance : une fuite trouvée et corrigée (`656b888`). Les vues fermées restaient rendues, jusqu'à 16 % de CPU au bout de quelques heures. Ajout de PulseBench.
- Conséquences sur le plan : toute nouvelle fenêtre est libérée à la fermeture et chaque étape ajoute sa phase dans PulseBench (intégré en 3a et 3f).
- Pour démarrer A, il faut ta décision sur l'adresse e-mail des commits.

### 26/11/2026 : étape A terminée
- Commits Pulse réécrits vers l'adresse noreply avec `git filter-branch` sur la plage `upstream/main..main` uniquement. 36 commits ; arborescence identique (diff vide) ; smctl toujours ancêtre. Sauvegarde locale : tag `backup/pre-fork`. `git config user.email` est passé à l'adresse noreply.
- Ancien dépôt renommé `pulse-archive` (privé, intact). Le fork `fstormacq/pulse` est public et a pour parent `leaperone/smctl`. Push en avance rapide `3045c35..522b576`, sans force. Issues et Actions activées, description et sujets renseignés.
- Problème rencontré : aucun (`git filter-repo` n'était pas installé, `filter-branch` suffisait pour une plage de commits).
- À faire de ton côté : vérifier le fork, puis décider de supprimer ou non `pulse-archive`. Conseillé : activer « Block command line pushes that expose my email » dans GitHub, rubrique Settings → Emails.
- Conséquence pour la suite : le CI du fork compile le package principal à chaque push ; on étudiera l'ajout d'`App/` en 4f. Phase 3 : en attente de ton feu vert (« on verra pour la partie 3 »).

### 26/11/2026 : étape 3a terminée
**Livré :**
- Onglet **Courbes** (780 × 560) : liste Presets / Mes courbes / Illisibles, détail avec graphique, résumé en clair (forme, capteurs, réponse, hystérésis, lissage), bouton Activer.
- Actions Dupliquer, Nouvelle (+), Renommer, Supprimer (avec confirmation ; un avertissement s'affiche si la courbe est le profil actif). Elles sont disponibles par menu contextuel, par le bouton « … » et par la barre +/−.
- Lien « Edit Curves… » dans le popover, qui ouvre l'onglet sur la courbe active.
- Sans daemon, les presets restent affichés en lecture seule avec un bandeau d'explication.
- 9 nouveaux tests (noms, résumés, actions du store, navigation).

**Ce qui n'a pas marché, et ce qu'on en retient :**
1. **La fuite du popover n'était pas vraiment corrigée** par `656b888`. Mettre `contentViewController` à `nil` dans `popoverDidClose` ne suffit pas, et `popoverDidClose` n'arrive même pas quand l'animation de fermeture ne peut pas se jouer (app inactive). Le popover caché continuait de rendre ses graphiques : 3,5 % de CPU et +75 Mo. Correctif : un `NSPopover` neuf à chaque ouverture, libéré dès `popoverWillClose`. Mesuré à 0,24–1 % une fois refermé. **Règle pour la suite** : ne jamais compter sur `…DidClose` pour libérer ; vérifier dans PulseBench que les fenêtres fermées n'ont plus de `NSHostingView`.
2. Les captures `PulseSnapshots` ne dessinent pas le fond de sélection des listes (barre noire). C'est une limite de `cacheDisplay`, pas un bug de l'app. **À vérifier à l'œil pendant ta revue.**
3. **Choix de conception** : « Renommer » ne change que le libellé. Le nom technique (CLI, TOML) reste celui donné à la création, pour ne pas casser le profil actif ni les scripts SSH. La CLI l'affiche sous le titre.

**Mesures :** app au repos à 0,07 % de CPU (17 Mo), objectif atteint. Daemon à 0,25 %, toujours un peu au-dessus de l'objectif (sera traité en 4f). PulseBench : onglet Courbes ouvert 1,8 %, refermé 0,5 %.

**Ajustements des étapes suivantes :**
- 3b/3c : l'éditeur remplace le résumé dans `CurveDetail`, pour les courbes perso uniquement. Les presets restent en lecture seule, avec Dupliquer.
- 3e : vérifier si le daemon recharge une courbe active qu'on enregistre sans `activate` (`upsertFanCurve` n'appelle `setFanProfile` que si `activate` est vrai). Si ce n'est pas le cas, réactiver la courbe après l'enregistrement.
- 3f : ajouter au bench un glisser simulé et une vérification automatique qu'aucune `NSHostingView` ne survit à la fermeture.

### 26/11/2026 : étape 3b terminée
**Livré :** `CurveDraft`, un modèle d'édition sans interface (type valeur). Chaque opération borne ses entrées au lieu d'échouer, si bien que le brouillon reste toujours accepté par le daemon.
- **Formes** : changement de famille en gardant la rampe ; poignées début (°C, min %) et fin (°C, max %) bornées entre 30 et 110 °C, avec au moins 2 °C de rampe et min ≤ max ; raideur entre 0 et 30 au dixième près ; 1 à 20 paliers.
- **Conversion en points** : les extrémités de la rampe, plus les points où la forme s'écarte le plus de son approximation (simplification gloutonne). Écart mesuré inférieur à 2 % sur 30–110 °C pour les trois presets. Les paliers ont leur propre conversion, exacte.
- **Points** : déplacement borné entre les voisins (0,5 °C d'écart minimum), ajout refusé trop près d'un autre point, au moins 2 points et au plus 24. Les configs écrites à la main (RPM, `max`, désordre) sont relues en %.
- **Capteurs** : groupes CPU, GPU et boîtier ; « hottest » ou « average » (poids égaux, `*` pour tous) ; les clés personnalisées sont conservées.
- **Réponse** : hystérésis (0–20 °C), montée et descente en %/s (0 = immédiat ; les vitesses en RPM sont converties), lissage (0–120 s).
- **Tests** : 11 nouveaux, dont un test aléatoire (200 séquences de 30 éditions, relancé 15 fois sans échec) qui vérifie que la courbe reste valide.

**Ce qui n'a pas marché, et ce qu'on en retient :**
1. Le test aléatoire a trouvé un cas : ajouter un point sur une *forme* donnait une courbe d'un seul point, refusée par le daemon. Les opérations sur les points sont désormais réservées aux courbes en points. **Pour 3c** : un double-clic sur une forme propose d'abord de la convertir en points.
2. Les contremarches des paliers compilés (1 % de la plage, soit 0,3 °C) étaient plus étroites que l'écart minimal entre points. Elles auraient été supprimées : d'où la conversion dédiée, avec des contremarches de 0,5 °C.
3. Annuler et rétablir est laissé à l'interface (3c) : le modèle étant un type valeur, il suffit d'enregistrer la spec précédente dans l'`UndoManager`, en un seul groupe par glisser.
4. Le push vers GitHub échoue : le jeton `gh` est devenu invalide après la reconnexion, et le trousseau macOS est inaccessible depuis cette session. Les commits restent en local jusqu'à ta reconnexion (`gh auth login`).

**Ajustements :**
- 3c : la plage de température affichée passe de 40–110 à 30–110 °C pour correspondre aux bornes du modèle.

### 26/11/2026 : étape 3c terminée
**Livré :**
- Éditeur des courbes perso dans l'onglet Courbes, avec :
  - un menu **Forme** (Linéaire, S, Exponentielle, Logarithmique, Paliers, Points) ;
  - un curseur de **raideur** ou un sélecteur du **nombre de paliers** ;
  - un graphique 30–110 °C avec poignées : deux extrémités pour une forme, chaque point en mode Points ;
  - glisser avec aimantation à 0,5 °C et 1 %, double-clic pour ajouter un point (une forme est d'abord convertie, en une seule étape annulable), clic pour sélectionner et Suppr pour retirer ;
  - poignées agrandies au survol, avec un curseur « main » ;
  - bascule **% / RPM** de l'axe vertical, avec graduations rondes (1000, 2000…) ;
  - Annuler et Rétablir (⌘Z / ⇧⌘Z), un pas par glisser ;
  - VoiceOver : une poignée = un élément ajustable (±1 °C), avec les actions « Faster » et « Slower » (±1 %).
- Boutons Annuler les modifications et Enregistrer (⌘S) en version simple ; 3e ajoutera les protections.
- `CurveEditorModel` (sélection, glisser, annuler) : 6 nouveaux tests. 2 autres tests pour le tracé et les graduations RPM.
- PulseBench : phase « éditeur ouvert/fermé » et mesure d'un glisser à 60 Hz.

**Ce qui n'a pas marché, et ce qu'on en retient :**
1. **Pas de poignée de raideur au milieu de la rampe** : une courbe en S passe toujours par 50 % en son milieu, quelle que soit sa raideur, donc la poignée ne bougerait pas. On garde un curseur.
2. Un sélecteur segmenté à six choix débordait de la fenêtre (530 points disponibles) : remplacé par un menu déroulant.
3. **Coût d'un glisser** : environ 13,7 ms de CPU par image au départ (rendu synchrone forcé), contre 5,5 ms pour un graphique Swift Charts minimal. Les essais ont montré que ni l'aire, ni les poignées, ni l'accessibilité, ni la couche de gestes ne pesaient. Ce qui pèse : les **axes personnalisés**, que Swift Charts recalcule à chaque changement de données (environ 4 ms), et les contrôles AppKit autour (environ 3 ms). Le graphique est maintenant séparé en deux couches superposées et alignées (axes fixes derrière, courbe devant), et il est tracé à partir de ses sommets (environ 30) au lieu de 161 échantillons. Résultat : 12,2 ms par image, soit −13 %. J'ai arrêté là : le reste vient du coût de base de SwiftUI et de Swift Charts, et il ne se paie que pendant un glisser. **Parade si le MacBook saccade (4d)** : limiter les mises à jour à 30 Hz pendant le glisser.
4. Le bench mesurait d'abord le « temps par image » en temps réel, attente de l'affichage comprise. Il affiche maintenant le CPU par image, qui est la vraie charge.

**Mesures :** app au repos à 0,12 % (17,7 Mo). PulseBench : éditeur ouvert 1,5 %, refermé 0,4 %, glisser 38 % pendant le geste.

**Ajustements des étapes suivantes :**
- 3d : les réglages d'entrée et de réponse (capteurs, agrégation, hystérésis, vitesses, lissage) deviennent éditables à la place du résumé, et la marque « température actuelle » s'ajoute dans la couche de la courbe. Les courbes fantômes des presets iront dans la couche fixe des axes, pour ne rien coûter pendant un glisser.
- 3e : brancher Enregistrer et Activer, gérer la sauvegarde d'une courbe active, protéger les modifications non enregistrées (changement de courbe, fermeture de la fenêtre).

### 26/11/2026 : étape 3d terminée
**Livré :**
- **Aperçu live** : une ligne orange pointillée à la température actuelle, un point sur la courbe et une lecture « Now 56 °C → this curve asks 0 % (1000 RPM) · fan at 7 % (1274 RPM) ». La température est calculée comme le fait le daemon (même fonction d'agrégation), mais sur les capteurs **du brouillon** : cocher GPU déplace la ligne avant même d'enregistrer.
- **Presets fantômes** : Silencieux, Équilibré et Performance en pointillés pâles, dans la couche fixe des axes. Ils ne coûtent rien pendant un glisser (11,2 ms par image, contre 12,2 avant).
- **Entrées et réponse éditables** (chaque changement est annulable) : cases CPU, GPU et Boîtier (aucune cochée = tous les capteurs), « Hottest sensor » ou « Average », montée et descente en %/s (0 = « Immediate »), hystérésis, lissage.
- **Phrase de conséquence** : « Minimum to full speed in 25 s, back to minimum in 50 s. Slows down only once 3 °C cooler. Ignores spikes shorter than about 15 s. »
- 3 nouveaux tests (entrée selon les capteurs et l'agrégation, capteur éteint ignoré, phrases de réponse).

**Ce qui n'a pas marché, et ce qu'on en retient :**
1. Le premier formulaire empilait des pas à pas avec des écarts irréguliers et des colonnes mal alignées. Il est passé sur une grille à 4 colonnes (libellé, valeur alignée à droite, flèches).
2. La température « maintenant » est instantanée, pas lissée comme celle du daemon (qui applique l'EMA). Elle peut donc sauter de quelques degrés entre deux lectures. C'est acceptable pour un aperçu, et la lecture le dit (« Now »).
3. **« Essayer 60 s » non développé.** Il faudrait une activation temporaire dans le daemon, avec retour automatique et sans désactiver le garde-fou. C'est faisable (environ ½ journée, avec tests), mais ça touche au daemon. On peut déjà enregistrer et activer, puis revenir au profil précédent depuis le popover. **Décision pour ta revue.**

**Mesures :** app au repos à 0,12 % (17,5 Mo). PulseBench : éditeur ouvert 1,7 %, refermé 0,35 %.

**Ajustements pour 3e :** l'onglet fait maintenant 780 × 660. Le bouton Activer de l'en-tête doit proposer d'enregistrer d'abord si le brouillon est modifié.

### 26/11/2026 : étape 3e terminée
**Livré :**
- **Enregistrer** (⌘S), **Annuler les modifications**, et un bouton d'en-tête qui devient **« Save & Activate »** (ou « Save » pour la courbe active) dès qu'il y a des modifications. Activer la version enregistrée alors que des modifications sont à l'écran serait trompeur.
- **Les modifications non enregistrées sont protégées** par la question « Save changes to “Night”? » (Enregistrer / Ne pas enregistrer / Annuler) dans tous les cas :
  - changement de courbe dans la liste ;
  - « Edit Curves… » depuis le popover ;
  - fermeture de la fenêtre ;
  - **quitter l'app**.

  La ligne de la courbe modifiée indique « Edited ».
- **Changements faits ailleurs** (CLI, SSH, autre fenêtre) pendant l'édition :
  - sans modification en cours, l'éditeur se recharge en silence ;
  - avec des modifications, un bandeau propose « Use Saved Version » ou « Keep My Edits » ;
  - un simple renommage ailleurs est intégré sans rien demander ;
  - le retour de notre propre enregistrement n'est jamais pris pour un conflit.
- « Dupliquer » sur la courbe en cours d'édition copie **ce qui est à l'écran** : les modifications partent dans la copie et l'original reste tel qu'enregistré. « Renommer » pendant l'édition passe par le brouillon.
- Une erreur d'enregistrement (validation du daemon, daemon absent) s'affiche dans l'éditeur, en rouge, et le brouillon est conservé.
- Les presets utilisent le même graphique que l'éditeur, en lecture seule, avec la lecture « maintenant » et la bascule %/RPM.
- Tests : 6 nouveaux côté app (sélection en attente, conflit, renommage, retour de notre enregistrement) et 1 côté daemon (une courbe active enregistrée s'applique au cycle suivant). Au total : 63 tests app, et 216 tests XCTest dans le package principal (j'avais compté 91 à tort : une seule des suites).

**Ce qui n'a pas marché, et ce qu'on en retient :**
1. Vérification faite : **le daemon relit la courbe active par son nom à chaque cycle**. Enregistrer une courbe active l'applique donc sans réactivation. Un test de non-régression verrouille ce comportement.
2. Pour protéger les modifications, l'éditeur a dû remonter de `CurveDetail` à `CurvesSettings`, avec une référence dans `SettingsNavigation` que le contrôleur de fenêtre consulte à la fermeture et au moment de quitter. **Règle** : tout état d'édition qui doit survivre à un changement de sélection appartient au volet, pas au détail.
3. Les captures ne montrent ni les dialogues ni le bandeau de conflit (il faudrait injecter un état). Ces chemins sont couverts par des tests de logique : **à vérifier à l'œil pendant ta revue**.
4. Performance preset (raideur entre 60 et 63 °C) : rien n'est changé. « Duplicate » puis le curseur de raideur ou la poignée de départ permettent maintenant d'en faire une version plus douce en quelques secondes.

**Mesures :** app au repos à 0,07 % (17,3 Mo). PulseBench : éditeur refermé 0,6 %, glisser 12 ms par image (inchangé).

**Pour 3f :** vérifier tout le parcours sur le vrai daemon (créer, activer, modifier en SSH, voir l'app suivre, supprimer), mettre le README à jour (capture de l'éditeur) et cocher la phase 3 dans la feuille de route.

### 26/11/2026 : étape 3f terminée, phase 3 close
**Validation :**
- **Parcours réel contre le daemon installé** (`PulseLiveCheck`), 13 vérifications sur 13 :
  - brouillon modifié comme dans l'app, puis enregistré et activé par XPC ;
  - le daemon le rapporte comme profil actif, avec une cible dans la plage du ventilateur ;
  - `pulse fan curve show` et `pulse status` le voient ;
  - une modification en CLI (« SSH ») est rechargée en silence par un éditeur sans modification, et signalée en conflit par un éditeur qui en a ;
  - retour sur Balanced, courbe supprimée.
- **PulseBench** vérifie maintenant automatiquement qu'aucune vue SwiftUI ne survit dans une fenêtre fermée : OK.
- README : ligne « Curve editor », capture de l'éditeur en clair et en sombre, consommation mise à jour, outils de mesure documentés. Feuille de route : phase 3 cochée.

**Ce qui n'a pas marché, et ce qu'on en retient :**
1. Le push vers GitHub échoue depuis 3a : le jeton `gh` est invalide et le trousseau n'est pas accessible depuis cette session. **6 commits attendent en local.** Après `gh auth login`, un simple `git push` suffit.
2. Les captures ne peuvent montrer ni la sélection de la liste, ni les dialogues, ni le glisser réel. Ces points sont couverts par des tests et par PulseLiveCheck, mais **un passage à l'œil reste nécessaire**.

**Bilan de la phase 3 :** 6 commits, environ 2 500 lignes. 63 tests côté app (dont un test aléatoire), 1 nouveau test daemon, 2 outils (`PulseBench` enrichi, `PulseLiveCheck`). Une fuite réelle corrigée en chemin (popover). App au repos à environ 0,1 % de CPU et 18 Mo.

**À regarder pendant ta revue (ce que je n'ai pas pu voir moi-même) :**
1. Le fond de sélection de la liste des courbes (barre noire dans les captures, normalement aux couleurs du système).
2. Le glisser des poignées et des points : fluidité, aimantation, curseur « main », double-clic, touche Suppr.
3. Les questions « Save changes…? » : en changeant de courbe, via « Edit Curves… » du popover, en fermant la fenêtre et en quittant.
4. Le bandeau de conflit : modifier une courbe dans l'app sans enregistrer, puis lancer `pulse fan curve set <nom> --hysteresis 4` dans un terminal.
5. ⌘Z / ⇧⌘Z dans l'éditeur.

**Décisions qui t'attendent :**
- ~~**« Essayer 60 s »**~~ : abandonné à la revue.
- **Preset Performance** : on le laisse, ou tu en fais une copie plus douce avec l'éditeur ?

**Ajustements pour la phase 4 :**
- 4b : le lancement au login est déjà là ; le test de redémarrage s'ajoutera à la campagne 4e.
- 4d : sur MacBook, mesurer le glisser avec `PULSE_BENCH_DRAG_ONLY=1 PulseBench`. Au-delà de 16 ms par image, appliquer la parade prévue (30 Hz pendant le glisser).
- 4e : réutiliser l'approche de `PulseLiveCheck` (étapes automatiques avec remise en état) pour les tests matériels qui ne demandent pas d'action physique.

### 26/11/2026 : après la phase 3, comportement à 0 % (avant la revue)
**Livré (`8ce69d5`, `0e2dc18`, `e73436b`, `785b752`) :**
- Une courbe qui demande 0 % rend le ventilateur à macOS, mais seulement après **15 s** passées à 0 %. Sans ce délai, la courbe et macOS se renvoyaient le ventilateur à chaque petite variation. La télémétrie indique ce passage de main.
- **Comportement à 0 %, réglable par courbe** : `idle = system` (macOS décide, par défaut), `minimum` (Pulse garde la vitesse minimale) ou `off` (le ventilateur s'arrête).
  - `off` exige `[safety] allow_below_minimum = true`.
  - Garde-fous : le ventilateur redémarre au-dessus de 75 °C pour les puces et de 50 °C pour les autres capteurs.
  - L'éditeur affiche un avertissement clair (« may harm your Mac »).
- Popover : la ligne du capteur TC est masquée quand des points chauds Tp existent.

**Test réel :** le ventilateur du Mac mini M4 accepte 0 tr/min. Il s'arrête en moins de 2 s et repart à 1 000 tr/min de façon fiable. Une courbe `idle = off` l'arrête bien après 15 s.

**Reste ouvert :**
- l'essai prolongé ventilateur arrêté (10–15 min au repos), pour valider les seuils de 75 et 50 °C ;
- tu as dit être repassé en mode sûr, mais **`/etc/pulse/config.toml` contient encore `allow_below_minimum = true`** au moment de cette entrée.

### 26/11/2026 : revue de la phase 3 (`8fcb594`)
**Tes retours et ce qui a été fait :**

| Retour | Correction |
|---|---|
| Sélection de la liste : gris clair | Normal : c'est la sélection du système quand la liste n'a pas le focus. Rien à changer. |
| Glisser fluide, mais valeur exacte difficile à lire | Étiquette « 74.5 °C · 4 % » (ou en RPM) au-dessus du point glissé, survolé ou sélectionné. Elle est dessinée dans une couche au-dessus des marques : en annotation Charts, le point voisin la recouvrait. |
| Les questions « Save changes…? » sont pénibles | **Enregistrement automatique** quand on quitte une courbe (autre courbe, « Edit Curves… », fermeture, quitter l'app). Pulse ne pose de question que si l'enregistrement échoue (courbe invalide, refus du daemon). Dans l'éditeur, Save et Revert restent disponibles. |
| « Essayer 60 s » | **Abandonné** : passer d'un profil à l'autre suffit. |
| La fenêtre de réglages change de taille selon l'onglet | **Une seule taille** (780 × 720) pour les quatre onglets. |
| La courbe se transforme en épines quand on bouge vite la raideur | Corrigé, voir ci-dessous. |
| Sélecteurs Hottest/Average et comportement à 0 % trop lourds | **Contrôles segmentés en petite taille** (même hauteur que %/RPM), steppers en petite taille, boutons ⓘ qui expliquent chaque réglage (capteurs, hottest/average, vitesses, 0 %, hystérésis, lissage, raideur). |

**Ce qui n'a pas marché, et ce qu'on en retient :**
1. **Les épines.** L'échantillonnage adaptatif des formes change le nombre de points à chaque cran de raideur. Swift Charts anime alors le passage d'un tracé à l'autre, avec des nombres de points différents, ce qui produit des épines pendant l'animation. Une capture statique ne le montre pas : il a fallu raisonner à partir du rendu animé. **Correctif** : les formes lisses sont dessinées sur une grille fixe de 0,5 °C (161 points), identifiés par leur indice, et les animations sont coupées. Un test vérifie que le nombre de points reste constant. **Règle** : toute série tracée par Charts garde des identifiants stables d'une mise à jour à l'autre.
2. Le curseur créait une étape d'annulation par cran. Un geste ne compte maintenant que pour une étape (`beginContinuousEdit` / `endContinuousEdit`), testé.
3. **Incident** : pour comparer avec l'ancienne version, j'ai mis l'arbre de travail de côté avec `git stash` pendant qu'un agent en arrière-plan modifiait le même fichier. Le retour du stash a échoué. Rien n'a été perdu (stash conservé et restauré, changement de l'agent réappliqué). **Règle** : ne jamais faire de `git stash` quand un agent peut travailler dans l'arbre. Pour comparer, utiliser `git worktree add`.
4. PulseBench est bruité d'une exécution à l'autre : éditeur ouvert à 4,8 %, puis 1,3 % en relançant. **Règle** : avant de conclure à une régression, relancer PulseBench au moins une fois et comparer à une référence mesurée dans un worktree.

**Mesures :**
- PulseBench :
  - éditeur ouvert 1,3 %, refermé 0,24 % ;
  - aucune vue SwiftUI ne survit à la fermeture ;
  - **glisser 7,1 ms par image** (contre 12 ms avant) : la grille fixe coûte moins cher que l'échantillonnage adaptatif.
- App réelle : entre 0,2 et 0,3 % les minutes suivantes, contre 0,07 % pour la référence. 140 Mo, sans doute parce que le popover ou les réglages ont été ouverts pendant la mesure. **À refaire au calme en 4a.**

**Décisions qui restent :**
- **Preset Performance** : proposition dans le message de revue (rampe linéaire de 50 à 85 °C, de 10 à 100 %). En attente de ta réponse.
- **Aide** : les boutons ⓘ couvrent l'immédiat. Une section « Aide » complète, qui explique l'effet de chaque réglage sur la ventilation, pourra s'ajouter en 4f avec la documentation de la 1.0.

**Ajustements pour la phase 4 :**
- **4a** : commencer par une mesure de l'app au repos sans interaction, pour fermer le point ouvert ci-dessus.
- **4e** : ajouter l'essai prolongé ventilateur arrêté (`idle = off`) à la campagne de tests.

### 26/11/2026 : étape 4a terminée (`03ac2d5`)
**Livré :**
- **Notifications** :
  - « Temperature limit reached » : nomme le capteur (« Tp0E reached 112 °C (limit 110 °C) ») et le profil mis en pause ;
  - « Temperatures back to normal », au refroidissement, avec un bouton **« Resume Profile »** qui réactive le profil interrompu.
- **Logique** (`SafetyAlertTracker`) :
  - une seule notification par transition ;
  - aucune pour un verrouillage déjà présent au lancement ;
  - « auto » et « manual » ne sont jamais proposés à la reprise ;
  - la télémétrie de secours (lecture directe des capteurs, sans daemon) est ignorée : elle ne connaît pas le garde-fou et produirait un faux « retour à la normale ».
- **Réglages > General** : interrupteur, activé par défaut, regroupé avec « Open Pulse at login ». Fenêtre passée à 780 × 760 pour que General tienne sans défiler.
- `scripts/test-safety-notification.sh` (avec `sudo`) : abaisse le plafond 3 °C sous la température la plus haute du moment pour déclencher le garde-fou (un plafond fixe à 45 °C ne déclenchait rien sur un Mac mini au repos), attend, puis restaure la config, même après Ctrl-C.
- 5 tests : transitions, lancement, messages, respect du réglage. 74 tests côté app au total.

**Ce qui n'a pas marché, et ce qu'on en retient :**
1. **Le plan se trompait sur le garde-fou.** Il ne met pas les ventilateurs au maximum : il les **rend à macOS** et **écrit `profile = "auto"` dans la config**. Le profil de l'utilisateur n'est donc pas rétabli après refroidissement. D'où le bouton « Resume Profile ». **Question pour plus tard** : faut-il que le daemon rétablisse le profil tout seul une fois le verrou relâché ? C'est plus pratique, mais une machine qui chauffe en boucle pourrait alors osciller. À trancher pendant la campagne 4e.
2. Le risque des notifications avec une signature ad hoc ne s'est pas concrétisé : une version sonde a obtenu `granted=true` et posté sans erreur. Point à surveiller : macOS pourrait redemander l'autorisation quand la signature ad hoc change à chaque build.
3. Ajouter un réglage a fait déborder General de la fenêtre (taille fixe depuis la revue). **Règle** : à chaque nouveau réglage, relire la capture de l'onglet concerné à la taille réelle.

**Mesures :** PulseBench : popover refermé 0,35 %, réglages refermés 0,41 %, éditeur refermé 0,40 %, aucune vue SwiftUI ne survit à la fermeture.
- **App réelle au repos**, sans battement, rien d'ouvert d'après l'échantillonnage : **0,33 % de CPU, 80 Mo**. La référence était de 0,07 % et 17 Mo.
  - L'échantillon ne montre que le sondage et le **redessin de l'icône** (`MenuBarRenderer.layoutReadings`), soit environ 15 ms par changement de valeur affichée.
  - Ce n'est pas lié à cette session : le Mac est plus chaud qu'au moment de la référence (points chauds entre 55 et 78 °C), donc les valeurs affichées changent plus souvent.
  - **À traiter en 4f** : arrondir ou retarder les valeurs de la barre des menus pour réduire les redessins, et chercher d'où viennent les 80 Mo au repos.

**Pour 4c (déclencheurs)** : c'est le prochain point qui demande une décision de ta part (où vivent les horaires : daemon, recommandé, ou app). La 4b se limite à un test de redémarrage, déjà rattaché à la campagne 4e.

### 26/11/2026 : tes décisions après la 4a
1. **Preset Performance** (`53e1c5a`) : rampe linéaire de 55 à 90 °C, de 10 à 100 %, sur la **moyenne CPU** (`Tp*`) au lieu du capteur le plus chaud. Les résumés disent « average » quand les poids sont égaux. **Le daemon installé garde l'ancien preset** tant qu'il n'est pas réinstallé (onglet Service).
2. **Déclencheurs** : pas d'horaires fixes. Ils suivront l'état du système. La 4c est réécrite ci-dessus, avec les résultats des tests de faisabilité.
3. **Après le garde-fou**, le Mac reste en automatique et c'est à toi de choisir à nouveau un profil. C'est le comportement actuel, gardé volontairement : il signale un problème de refroidissement. Conséquence pour la 4c : les règles automatiques sont suspendues après un déclenchement, jusqu'à ton choix.

### 26/11/2026 : bug de réinstallation du daemon, CI
- **Bug** : « Reinstall… » semblait faire planter l'app et fermer la fenêtre. En réalité, l'app tournait toujours (aucun rapport de plantage, processus vivant).
  - La demande de mot de passe passait par `NSAppleScript` sur le fil principal, ce qui gelait l'app tant qu'elle était ouverte.
  - Une fois la demande fermée, macOS réactivait l'app précédente, et la fenêtre de Pulse (pas d'icône dans le Dock) restait cachée derrière.
  - **Correctif** (`6fa175c`) : `osascript` dans un processus séparé, hors du fil principal, puis retour de la fenêtre au premier plan. Les messages d'erreur sont nettoyés (testé).
  - **Règle** : rien de bloquant sur le fil principal, même quand on attend l'utilisateur.
- **CI** (`106f9ec`) : la compilation macOS n'est plus lancée pour les changements de documentation seule (`*.md`, `docs/`, `assets/`, `LICENSE`).
- **4c recadrée** : Mode Jeu en priorité, puis économie d'énergie et secteur/batterie. Concentration en option, Night Shift abandonné.

### 26/11/2026 : étape 4c terminée (`03d496d`)
**Constat sur le Mode Jeu** (deux parties avec `scripts/gamemode-probe.sh`) :
- aucune notification Darwin de `gamepolicyd` reçue ;
- aucune clé dans le SCDynamicStore ;
- rien dans le journal système ;
- et les jeux testés ne déclarent pas la catégorie « jeux » dans leur `Info.plist` (une app iPhone/iPad n'en déclare pas non plus).

macOS n'offre donc **aucun signal fiable**, et sa propre heuristique ne reconnaîtrait même pas ces jeux. **Décision** : la condition est « une de ces apps est ouverte ». Tu choisis tes jeux une fois. Si tu choisis un lanceur, les apps qu'il contient sont reprises aussi (un lanceur peut contenir le vrai jeu).

**Livré :**
- **Réglages > Automation** :
  - règles « When ‹condition›, use ‹profile› » ;
  - activation règle par règle, ordre via « Move Up / Down » ;
  - ligne d'état (« Now: Performance, because Chess is open », ou « Paused after the temperature limit… »).
- **Conditions** : app ou jeu ouvert ; économie d'énergie ; sur batterie / sur secteur (proposées seulement sur un Mac avec batterie).
  - Toutes sont observées par notifications système (`NSWorkspace`, `NSProcessInfoPowerStateDidChange`, `IOPSNotificationCreateRunLoopSource`). **Aucun sondage.**
  - Les règles sont évaluées au rythme du sondage existant du store (2 s), via un crochet `onRefresh`.
- **`AutomationEngine`** (logique pure) :
  - une condition doit tenir 5 s avant d'agir ;
  - la première règle qui correspond l'emporte ;
  - sans règle active, retour au profil de base ;
  - un choix manuel (app ou CLI) devient le profil de base et suspend les règles en cours jusqu'à ce que leur condition disparaisse ;
  - après un déclenchement du garde-fou, les règles sont suspendues jusqu'à ton choix.
- Les événements du garde-fou sont maintenant diffusés à plusieurs abonnés (notifications et automatisation).
- 12 nouveaux tests. Au total : 86 tests côté app.

**Ce qui n'a pas marché, et ce qu'on en retient :**
1. **Course entre la bascule et le sondage.** Juste après une bascule, un sondage pouvait encore rapporter l'ancien profil. Le moteur le prenait pour un choix manuel et suspendait la règle. **Correctif** : il attend que le daemon confirme (10 s au plus). Pendant cette attente, un profil qui n'est ni l'ancien ni le nouveau compte comme un choix manuel. Si le daemon refuse, la bascule est retentée. Les trois cas sont testés.
2. Un test simulait des dates futures alors que les sondages utilisent l'heure réelle. **Règle** : dans les tests qui mélangent un tick simulé et le vrai sondage, ne simuler que le passé.
3. Le libellé masqué d'un `Picker` dans une ligne de `Form` prenait de la place et tronquait le texte de la règle. Le libellé est maintenant caché, et le texte a la priorité.

**Test réel contre le daemon** (règle « Échecs ouvert → Performance », retirée ensuite de tes préférences) :
- Échecs ouvert → Performance en environ 9 s (5 s de stabilisation, plus le sondage) ;
- Échecs fermé → retour à `balanced-copy` en 2 s ;
- `pulse fan profile silent` pendant la partie : respecté, puis Silent reste après la fermeture d'Échecs.

**À faire de ton côté** : créer ta règle jeux → Performance (ou une courbe « gaming ») dans Réglages > Automation.

**Mesures :**
- App réelle au repos, battement coupé : **0,10 % de CPU** (contre 0,33 % avant la 4c), soit aucun coût mesurable de l'automatisation.
- Avec ton réglage de battement « toujours » : 2,8 %, conforme au coût connu du battement (environ 2,5 %).
- La mémoire reste à 80 Mo : point toujours ouvert pour la 4f.
- **Règle** : toujours mesurer avec `--args -menuBarHeartbeat off`. Une mesure lancée par un simple `open` hérite de ton réglage « toujours ».

### 26/11/2026 : étape 4d sur MacBook Pro M1 Pro (MacBookPro18,3, macOS 27.2.1)
**Matériel constaté** (`pulse doctor`) :
- **2 ventilateurs** avec des plages différentes : 1200–5779 et 1200–6241 RPM ;
- **pas de clé `Ftst`** : le déblocage passe par le **chemin direct** (`F0Md = 1` accepté tel quel) ;
- capteurs Tp×14, TC×12, Tg×4, Ts×8 ;
- batterie lisible, mais **aucune clé de contrôle de charge** (ni `CHTE` ni `CH0B`/`CH0C`). Seul le contrôle de l'adaptateur (`CHIE`) existe.

**Écriture sur les ventilateurs : validée.** Une consigne manuelle de 2 500 RPM, puis le test `pulse doctor --test-fans` à 40 % : les deux ventilateurs atteignent la cible en environ 5 s. Avec une courbe à 0 %, ils reviennent à macOS après 15 s (`auto`, 0 RPM). Le journal du daemon indique « via direct ». **Le chemin `Ftst` reste non validé** : il concerne les MacBook M3/M4, qu'on n'a pas.

**Livré :**
- `6550c21` **correctif hérité de smctl** : sans clés de contrôle de charge, l'état « charge autorisée » était lu comme faux. La politique voulait réactiver la charge, échouait, et journalisait l'erreur (avec un envoi Sentry) toutes les 10 s. L'évaluation ne fait plus rien dans ce cas ; une limite configurée est signalée une seule fois dans le statut du daemon. Correctif générique, candidat à une PR vers smctl.
- `dbc184e` : `pulse battery status` affichait « charging: disabled » sur ce Mac. Sans clés de contrôle, l'état de charge vient maintenant d'IOKit (`IsCharging`).
- `593ba6b` **`pulse doctor`** (texte ou `--json`) :
  - modèle, puce, macOS ;
  - ventilateurs (plage, clé de mode), présence de `Ftst` et chemin de déblocage attendu ;
  - contrôle de charge et d'adaptateur, groupes de capteurs ;
  - version du daemon et de la CLI, dernière erreur, garde-fou, outils concurrents ;
  - une liste de vérifications ✓ / · / ! / ✗ ;
  - `--test-fans` : 40 % sur chaque ventilateur, attente de la stabilisation, retour au profil d'origine (même après Ctrl-C).
  - 8 tests.
- `5423d89` **interface** :
  - **Mac sans ventilateur** (MacBook Air) : le popover masque les profils et la légende « Fan », son état affiche « No fan » ; les onglets Courbes et Automation expliquent qu'il n'y a rien à piloter ;
  - **MacBook Pro** : l'axe RPM de l'éditeur suit le ventilateur 1, avec une note quand les autres ont une autre plage (« Fan 2 runs the same % on 1200–6241 RPM ») ;
  - `SampleService` accepte une plage par ventilateur ; captures MacBook Pro et sans ventilateur ajoutées ;
  - 4 tests (90 côté app au total).
- `001725c` (agent séparé) : les libellés de température de l'éditeur sont centrés sous leur graduation.

**Mesures (M1 Pro) :**
- PulseBench (2 passages) :
  - toutes les phases « fermé » entre 0,5 et 0,8 % ;
  - aucune vue SwiftUI ne survit à la fermeture ;
  - « réglages ouverts » à 8 % puis 3,2 % (bruit) ;
  - **glisser à 11,6 ms par image** (sous 16 ms) : la limite à 30 Hz est inutile.
- App réelle au repos, battement coupé : **0,37 % de CPU, 78 Mo** (M4 : 0,10 %).
- Daemon : **0,52 %, 15 Mo** (M4 : 0,22 %). Mesuré avec l'ancien daemon, qui journalisait encore l'erreur batterie toutes les 10 s.
- Le M1 Pro est plus lent par cœur que le M4, mais l'écart dépasse ce qu'explique la puce. **Pour la 4f**, à profiler sur ce MacBook.

**Ce qui n'a pas marché, et ce qu'on en retient :**
1. `pulse debug keys --prefix …` énumère toutes les clés SMC, ce qui prend plus de 20 s sur ce Mac. **Règle** : sonder des clés précises avec `pulse debug read`.
2. Refuser une limite de charge sans clés de contrôle cassait 4 tests d'upstream (la config doit pouvoir la stocker). On la signale au lieu de la refuser.
3. Sans l'autorisation d'enregistrement d'écran, la liste des fenêtres ne montre pas les éléments de la barre des menus. Impossible de vérifier l'encoche automatiquement.
4. `zsh` a un `log` intégré : appeler `/usr/bin/log`.

**À faire de ton côté :**
1. **Réinstaller le daemon** (Réglages > Service) : le build 127 contient les correctifs batterie. Je vérifierai ensuite que l'erreur a disparu des journaux et je referai la mesure du daemon.
2. **Encoche** : l'icône Pulse est-elle visible ? Si trop d'icônes sont présentes, macOS masque celles qui tombent sous l'encoche.
3. **Règle batterie** : Réglages > Automation > « On Battery → Silent », débrancher le chargeur, vérifier la bascule (environ 7 s), rebrancher et vérifier le retour.

**Ajustements :**
- **4e** : `pulse doctor --test-fans` devient la première étape de la campagne, sur chaque Mac.
- **4f** : profiler l'app (0,37 %) et le daemon (0,52 %) sur le M1 Pro, après la réinstallation ; la mémoire de l'app (78 Mo) reste ouverte.

**Clôture (même jour) :** tes trois vérifications sont bonnes : icône visible à côté de l'encoche, bascule « On Battery → Silent » puis retour, daemon réinstallé. Le daemon réinstallé à 18 h 07 contient le correctif : plus aucune erreur « Battery policy evaluation failed » depuis. CPU du daemon au repos : environ 0,4 % sur 30 s, encore au-dessus de l'objectif ; c'est l'objet de la 4f.

### 26/11/2026 : étape 4f, profilage sur le MacBook Pro M1 Pro
**App** (battement coupé, fenêtres fermées) : 0,14 à 0,15 % de CPU. Il ne reste que l'interrogation du daemon toutes les 2 s ; aucun redessin de la barre des menus au repos. Mémoire : les 78 Mo mesurés en 4d étaient le RSS, qui compte les frameworks partagés. L'empreinte réelle (`phys_footprint`) est de **20 Mo**, sous l'objectif. Le battement « Always » coûte environ 4 % sur ce Mac (redessin de chaque réplique de l'élément de barre des menus) : c'est un choix de l'utilisateur, hors objectif.

**Daemon** : la capture (`sudo sample`, 60 s, courbe active) montre que **97 % du travail sont des lectures SMC**, à raison d'environ 57 clés par tick d'une seconde : 38 températures (67 %), 10 clés ventilateur (17 %), 11 clés batterie et puissance (16 %). Le moteur de courbe et l'encodage XPC sont négligeables. Banc d'essai hors daemon : un snapshot coûte 1,6 ms de CPU, une lecture 26 µs de CPU pour 230 µs d'attente.
- `5548dbd` : en profil auto, sans alerte ni garde-fou verrouillé, le tick ne lit plus les capteurs ; `getTelemetry` relit à la demande quand le snapshot a plus de 1,5 s. Courbes, consignes manuelles, alertes et garde-fou lisent toujours chaque seconde.
- Avec une courbe active : **0,60 %** de CPU, 14 réveils par seconde. Correction : les 82 réveils par seconde de la première mesure ne venaient pas des lectures SMC (le daemon n'en fait plus que 14 avec le même nombre de lectures).

**Conséquence** : à 1 s, le coût suit le nombre de lectures. Pour approcher 0,2 % avec une courbe, il faut lire moins souvent (proposition de l'utilisateur : intervalle de collecte réglable de 1 à 5 s) ou lire moins de clés (batterie et puissance à la demande, environ −16 %).

### 26/11/2026 : étape 4f, intervalle de collecte (ta proposition)
- `c26ec25` : `[fan] interval`, de 1 à 5 s, 2 par défaut. Le minuteur reste à 1 s, mais les lectures SMC ne se font qu'au rythme choisi. À moins de 20 °C du plafond d'un capteur, ou quand le garde-fou est verrouillé, lecture chaque seconde : il se déclenche donc aussi vite qu'avant. Vitesses de variation, lissage et délai de passage à macOS sont calculés en temps écoulé, donc les courbes gardent leur comportement. Batterie et puissance ne sont plus lues à chaque tick (puissance lue à la demande pour la télémétrie).
- `80d578c` : slider à 5 crans dans Réglages > Général > Sensors ; l'app interroge le daemon au même rythme, popover ouvert compris.
- `c607f26` et suivant : `[fan] battery_interval`, optionnel. Le daemon suit la source d'alimentation par notification IOKit : la bascule est immédiate et fonctionne app fermée, ce qui explique ce choix plutôt qu'une règle d'automatisation (elles ne tournent qu'app ouverte). Dans l'app, un second slider « On battery » sur les Mac à batterie ; l'onglet Automation y renvoie. CLI : `pulse fan interval 5 --on-battery`, `same` pour le retirer.

**Mesures, daemon avec courbe active (M1 Pro, 2 min par palier) :**

| Intervalle | CPU du daemon |
|---|---|
| 1 s | 0,62 % |
| 2 s (défaut) | 0,30 % |
| 5 s | **0,14 %** |

- L'objectif de 0,2 % est atteint à partir de 3 s avec une courbe active, et dès 2 s en profil auto (aucune lecture hors demande de l'app).
- PulseBench : phases fermées entre 0,4 et 0,8 %, aucune vue SwiftUI restante, glisser à 11,4 ms par image.
- **Reste de la 4f** : CI pour `App/`, section Aide, version 1.0. **Puis 4e**, sur le MacBook et le Mac mini (le script devra tester la bascule d'intervalle au débranchement).

### 26/11/2026 : correctif de la fenêtre après le mot de passe (`ee450a3`)
- **Symptôme** : à « Reinstall… », une fois le mot de passe saisi, une autre app passait au premier plan et la fenêtre Réglages restait derrière.
- **Cause** : la fenêtre de mot de passe appartient à un autre processus. Quand elle se ferme, macOS active l'app classique précédente, pas Pulse (app de barre des menus, sans icône dans le Dock). Le `NSApp.activate()` de fin est coopératif : il est refusé, puisque l'utilisateur n'a pas demandé ce changement et que personne ne cède la place. Reproduit avec une app d'essai : `activate()` et `NSRunningApplication.activate(options:)` échouent, `activate(from:)` et `activate(ignoringOtherApps:)` (dépréciée) réussissent.
- **Correctif** : un `ActivationGuard`, armé pendant les actions qui demandent le mot de passe (installation, réinstallation, lien CLI), annule aussitôt toute activation d'une app classique avec `activate(from:)`. Les hôtes de la fenêtre de mot de passe (SecurityAgent, osascript) ne sont pas des apps classiques et ne sont pas concernés. Chaque activation est journalisée (catégorie `activation`). **Validé par toi.**
- **Règle** : pour reprendre le premier plan après une action système, utiliser `activate(from:)`, jamais `NSApp.activate()` seul.

### 26/11/2026 : où on en est, et la suite
- **Terminé** : A (sauf la suppression de `pulse-archive`), phases 0 à 3, 4a à 4d, et dans la 4f : profilage, intervalle de collecte, correctif de fenêtre.
- **Suite proposée, dans l'ordre** :
  1. **Fin de la 4f, partie code** : CI pour `App/` (si les runners GitHub ont Xcode 26), section Aide dans les Réglages.
  2. **4e, campagne de tests matériels** : un script guidé, à lancer sur le MacBook puis sur le Mac mini. Il commence par `pulse doctor --test-fans`, puis couvre installation, changement de profil, veille, `kill -9`, redémarrage, garde-fou (`scripts/test-safety-notification.sh`), outil concurrent, bascule d'intervalle au débranchement (MacBook) et essai prolongé ventilateurs arrêtés (Mac mini).
  3. **Dépôt et publication**, à décider ensemble : signature (ad hoc ou compte développeur), version 1.0 et notes, archive de `Pulse.app`, PR vers smctl, suppression de `pulse-archive`.

### 26/11/2026 : fin de la partie code de la 4f
- **CI** (`ci: build and test…`) : nouveau job « App Build & Test (macOS 26) ». L'image `macos-26` de GitHub a Xcode 26 (Swift 6.3, SDK macOS 26), ce qui suffit à l'app. Premier passage réussi pour les deux jobs. Les tests de l'app tournent sur `SampleService` : ni SMC, ni daemon, ni droits.
- **Aide** (`76ae361`) : onglet « Help » dans les Réglages, huit sujets (fonctionnement, profils, lecture d'une courbe, réglages de réponse, rythme des capteurs, automatisation, limite de température, dépannage avec `pulse doctor`). Les plages des presets, les plafonds du garde-fou et la plage du rythme sont lus dans le code ; les réglages de réponse reprennent les textes des boutons ⓘ. Rien ne peut donc diverger de l'app. 4 tests, captures vérifiées en clair et en sombre.
- **Porte de validation** : 98 tests app, tous les tests du package, PulseBench (phases fermées entre 0,4 et 0,8 %, aucune vue restante, glisser à 11,5 ms par image).
- **Ensuite** : la 4e ensemble, sur le MacBook puis le Mac mini. La publication suivra, avec tes décisions.

### 26/11/2026 : l'aide sort des Réglages (ta demande)
- Un onglet Help à côté de About n'avait pas sa place. L'aide devient un document, [`docs/HELP.md`](HELP.md), avec le même contenu (tableau des profils, réglages de réponse, rythme des capteurs, automatisation, limite de température, dépannage).
- Pulse est une app de barre des menus, sans menu Help macOS : le lien « Help » est dans le pied du popover, entre Settings… et Quit (raccourci ⌘?). Il ouvre la page GitHub du document.
- L'onglet est retiré. Le document est écrit à la main, mais 2 tests (`HelpDocumentTests`) vérifient que ses chiffres suivent le code : plages des presets, capteur suivi, plancher de Performance, plafonds du garde-fou, plage du rythme.
- **Ensuite** : le script de la campagne 4e, qu'on lance ensemble, puis la réflexion sur la publication.

### 26/11/2026 : script de la campagne 4e
- `scripts/hardware-campaign.sh` : 13 tests, lancés tous ou par numéro (`--list`). Les vérifications automatiques tournent seules ; le script demande quand il faut un clic, débrancher le chargeur, ou le mot de passe pour sudo. Résultats dans `docs/campaign/<modèle>-<date>.md`, une ligne par test avec les mesures. Profil et intervalles restaurés à la sortie, même après Ctrl-C.
- Tests : 1 `doctor --test-fans` · 2 profil par la CLI · 3 profil depuis l'app (et SSH si la session à distance est active) · 4 intervalle, et bascule au débranchement sur MacBook · 5 fermeture de l'app · 6 `kill -9` du daemon · 7 veille et réveil · 8 charge soutenue CPU et GPU (`scripts/campaign/pulse-stress.swift`, 300 s, puis 90 s de retour au calme) · 9 outil concurrent (faux processus « Macs Fan Control ») · 10 garde-fou provoqué et notifications · 11 désinstallation et réinstallation · 12 ventilateurs arrêtés 30 min (Mac mini) · 13 redémarrage (`--after-reboot` à la reconnexion).
- Essayés sur le MacBook sans action de ta part : 1, 2, 4 (sans débranchement), 5 et 9, tous réussis.
- **Pièges** : une copie de `/bin/sleep` est tuée par macOS (binaire système hors de `/bin`), et un lien symbolique garde le nom « sleep ». Le faux concurrent est donc un petit programme C compilé à la volée.
- **Test 8 refait** : `yes` ne chauffait pas assez. Erreur de diagnostic au passage : `yes` tire autant de puissance qu'un calcul vectoriel (18 W contre 19 W sur le M1 Pro). Ce qui manquait, c'est le GPU et la durée. La nouvelle charge (`scripts/campaign/pulse-stress.swift`, compilée à la volée) fait des FMA vectorielles sur tous les cœurs **et** un noyau Metal sur le GPU : environ 40 W, CPU de 61 à 89 °C en 20 s, ventilateurs jusqu'à 4 000–5 000 RPM, garde-fou non déclenché. Elle dure 5 min par défaut (`LOAD_SECONDS`), puis 90 s de retour au calme (`COOL_SECONDS`). Le résultat note la puissance maximale, les pics CPU et GPU, le moment où les ventilateurs accélèrent (300 RPM au-dessus du départ) et leur vitesse après le retour au calme.

### 26/11/2026 : retours de la campagne, MacBook puis Mac mini
- **MacBook Pro M1 Pro** : tous les tests réussis sauf le 11, qui a révélé deux choses. **Bug réel** (`6e72880`) : `sudo pulse daemon install` échouait par le lien `/usr/local/bin/pulse`, puisqu'il cherchait `pulsed` à côté du lien. **Attente fausse du test** (`9060c88`) : une désinstallation enregistre `auto` (comportement smctl, voulu), alors que la réinstallation par-dessus garde le profil. Le test 13 ne remettait pas tes réglages avant le redémarrage (`24cb34a`). La charge du test 8 passe à 90 s (5 min, c'était trop).
- **Mac mini M4** : le test 1 échouait. **Bug réel**, hérité de smctl : sans batterie, le daemon enregistrait une erreur toutes les 10 s, que `pulse doctor` remontait en avertissement. Corrigé : pas d'erreur sans batterie, sauf si une limite de charge est configurée. Le script a été revu pour chaque type de Mac : sans ventilateur, capteurs CPU `TC*`, app hors de `dist/`, CLI hors du PATH sous sudo, recherche exacte du daemon, prérequis vérifiés.
- **Balanced plus calme** (ta demande) : montée 3 %/s, descente 1 %/s (environ 33 s jusqu'à pleine vitesse et 100 s pour redescendre, contre 13 s et 33 s). Silent reste plus rapide (5 / 2 %/s) : il démarre tard, à 80 °C, et doit rattraper.
- **Pour appliquer** : réinstaller le service sur les deux Mac (nouveau daemon et preset). Sur le Mac mini : `git pull`, `scripts/build-app.sh`, relancer Pulse, Reinstall, puis relancer la campagne.

### 26/11/2026 : étape 4g, stress test pour régler les courbes (ta demande)
- **Ton retour** : le test 10 de la campagne ne déclenchait rien sur le Mac mini. Ce n'était pas `sudo` : le plafond fixe de 45 °C était au-dessus de tous les capteurs au repos (41 °C au plus, sur un hot-spot Tp* qui a 10 °C de marge). Corrigé (`8f91b57`) : plafond 3 °C sous la température du moment.
- **Moteur partagé** (`SMCtlClient/PulseStress.swift`) : la charge CPU + GPU du test 8, portée en Swift dans le processus (threads arrêtables, noyau Metal) ; relevés toutes les 2 s ; attente du retour à la température de départ avant chaque profil ; synthèse (CPU stable, vitesse stable et écart type, accélération à +300 RPM, 90 % de la montée, retour au repos à 100 RPM près, garde-fou). Le profil d'avant est restauré même après un arrêt. 7 tests, dont le runner sur un faux Mac (charge injectée).
- **CLI** : `pulse fan stress`, relevés en direct, tableau comparatif (une colonne par profil), `--csv`, `--json`, Ctrl-C arrête proprement. Essayé sur le Mac mini : 32 W, CPU de 40 à 80 °C en 20 s, profil restauré, aucun processus restant.
- **App** : bouton « Stress Test… » dans l'en-tête d'une courbe (désactivé tant que des modifications ne sont pas enregistrées : le test lance la courbe enregistrée). Feuille avec durée (1, 2, 5 min) et type de charge, graphiques en direct alignés (températures et entrée lissée de la courbe, vitesse), relevé du moment, synthèse à côté de l'essai précédent de la même courbe, tracé en pointillés. Capture ajoutée à `PulseSnapshots`.
- **Au passage** (ta demande) : en RPM, le haut du graphique de l'éditeur n'avait pas d'étiquette (graduations à 1000, 2000, 3000, 4000 pour un maximum à 4900). Les vitesses minimale et maximale sont maintenant toujours graduées.
- **À essayer** : un vrai stress test depuis l'app (je n'ai validé que les captures et la CLI), et lancer l'app avec le nouveau binaire (`scripts/build-app.sh`).

### 27/11/2026 : décisions pour la publication (4h)
- **Campagne 4e** : réussie sur le Mac mini. Étape close.
- **Modèle de distribution** : tap Homebrew et Makefile, comme `sebsto/wispr`. Différence : wispr est notarisé (compte Apple) et publié à la main depuis le Mac, alors que Pulse est signé ad hoc et publié par la CI. C'est pour ça qu'il faut un token (`TAP_TOKEN`) : le jeton par défaut d'un workflow ne peut pas écrire dans le dépôt du tap.
- **Mise à jour du daemon** : par l'app et par le CLI à l'usage. Pas de `sudo` dans le cask, et pas d'auto-téléchargement par le daemon (trop sensible pour la 1.0). Détail et étapes dans la 4h.
- **Ruleset de `main`** : 1 approbation exigée, gardée volontairement. Tu préfères forcer le merge de tes propres PR plutôt que risquer un merge sans ton accord. Le contournement ne marche que par PR, donc aucun push direct.
- **Cask** : retire la quarantaine (`postflight`).

### 27/11/2026 : étape 4h.1, une seule version
- `Sources/ProductIdentity/PulseVersion.swift` porte la version : `0.0.0-dev` dans le dépôt. `scripts/set-version.sh x.y.z` l'écrit pour une release, et `--dev` la remet. `SMCtlProtocolInfo.version` et `PolicyEngine.version` (deux `"0.2.4"` hérités de smctl) la reprennent. `pulse --version`, le daemon, l'app (À propos) et l'`Info.plist` affichent donc tous la même valeur.
- `SMCtlProtocolInfo.isRelease` : une version de développement ne se compare à rien. Elle ne propose aucune mise à jour et n'en déclenchera aucune pour le daemon (étape 6). 2 tests ajoutés.
- `scripts/build-app.sh` ne prend plus de version en argument. Il lit celle du fichier et met la partie numérique dans `CFBundleShortVersionString` (`0.0.0` pour un build de développement).
- La CI tourne aussi sur `dev`.
- **Porte** : tous les tests du package passent, ainsi que les 96 de l'app (96 aussi avant le changement : l'écart avec les 98 notés plus haut vient du retrait de l'onglet Aide). `Pulse.app` construite, et un build en 9.9.9 vérifié puis remis en développement.

### 27/11/2026 : étapes 4h.2 à 4h.7 (en autonomie)
- **Makefile et scripts** (`173d10f`) : `make build|test|app|package|next-version|notes|tap|release`.
  - `scripts/package.sh` produit `Pulse-<v>.zip`, `pulse-cli-<v>-arm64.tar.gz` et `SHA256SUMS`. Le tar.gz contient les binaires signés de l'app.
  - `next-version.sh` calcule la version ; vérifié sur un dépôt jetable (docs seuls, fix, perf, feat, `!`, `BREAKING CHANGE`, commit de merge).
  - `release-notes.sh` groupe les commits et reprend `docs/release-notes/<v>.md` s'il existe (texte de la 1.0.0).
  - `scripts/release.sh` (Developer ID de leaperone) est supprimé.
- **Workflow** : un push sur `main` lance tests, packaging, release GitHub, puis met à jour le tap avec `TAP_TOKEN`. Une PR vers `main` (`8c84178`) et un lancement à la main construisent seulement, sans rien publier. Si on relance après une mise à jour du tap ratée, la release n'est pas refaite et le tap reprend les checksums publiés.
- **Tap** :
  - `packaging/homebrew/*.rb.in` → `Casks/pulse.rb` et `Formula/pulse-cli.rb`.
  - **Homebrew 7** : `postflight` est remplacé par `postflight_steps` (étapes déclaratives) ; le retrait de quarantaine s'écrit `run "/usr/bin/xattr", args: [..., "{{appdir}}/Pulse.app"]`.
  - Un cask ne peut déclarer de conflit qu'avec un autre cask. Brew refuse de toute façon de lier un deuxième `pulse` au même endroit.
  - Vérifié : `brew style` sans remarque ; cask et formule chargés depuis un tap local temporaire ; **formule installée depuis le tar.gz** (`pulse --version` = 1.0.0, signature ad hoc, pas de quarantaine, `brew test` réussi), puis désinstallée et tap retiré.
  - Le cask n'a pas été installé : cela aurait remplacé ton Pulse. C'est à faire à l'étape 8.
- **Détection et mise à jour** (`d701399`) :
  - `InstallChannel` (cask, formule, téléchargement, source) donne la commande de mise à jour. `DaemonUpdateDecision` ne met à jour qu'entre deux releases, vers l'avant ; les builds de développement ne sont jamais concernés.
  - **CLI** : `DaemonClient.outdatedDaemonHandler` lance `sudo pulse daemon install`, puis rouvre la connexion XPC. Seulement dans un terminal, ni avec `--json`, ni depuis `pulse daemon …`, ni avec `PULSE_NO_DAEMON_UPDATE=1`.
  - **App** : `UpdateCenter`.
    - Le remplacement est automatique, une fois par version du daemon, avec un message dans la fenêtre de mot de passe.
    - Si l'utilisateur annule, ou en cas d'échec, l'avis « service out of date » propose « Update… ».
    - L'avis « Pulse X is available » propose « Copy Command » ou « Download… », et « Later ». À propos affiche aussi la nouvelle version.
    - La dernière version passe par la télémétrie (`latestVersion`) ; sans daemon, l'app interroge GitHub une fois par jour.
- **Docs** : README (installation brew, téléchargement et « Ouvrir quand même », mises à jour, sources, releases), section « Updates » de `HELP.md`, notes de la 1.0.0, feuille de route.
- **Porte** :
  - tests : tous ceux du package passent, et les 103 de l'app (7 nouveaux pour `UpdateCenter`, 6 pour le canal, la décision et le CLI) ;
  - PulseBench : phases fermées entre 0,38 et 0,86 % ;
  - captures `popover-updates` et `settings-about` relues ;
  - avec une version de release, une commande hors terminal ne fait qu'avertir.
- **Non testé faute de release** : le remplacement réel du daemon (mot de passe), le cask installé et le workflow publié. C'est l'objet de l'étape 8.

### 27/11/2026 : v1.0.0 publiée, validation (étape 4h.8)
- **Publication** : le merge de la PR #1 (`ec1f4ec`) a déclenché le workflow : tests, build, release [v1.0.0](https://github.com/fstormacq/pulse/releases/tag/v1.0.0) (zip de l'app, tar.gz du CLI, `SHA256SUMS`), puis le tap mis à jour (`d947f7f`) avec `TAP_TOKEN`. Les checksums du tap correspondent aux fichiers publiés.
- **Piège découvert** : le dépôt officiel de Homebrew a déjà un cask `pulse`, une autre app (Pulse d'egoist, moniteur système). `brew install --cask pulse` l'installe à la place du nôtre. Installée par erreur sur le MacBook puis désinstallée ; tes réglages n'ont pas été touchés. **Décision (ta préférence)** : on garde le nom `pulse` et on écrit toujours le nom complet `fstormacq/tap/pulse` (et `fstormacq/tap/pulse-cli`) : README, aide, tap, notes de version, et commande proposée par l'app et le CLI. La détection du canal « cask » exige aussi que Pulse soit dans Applications, pour ne pas confondre avec l'autre `pulse`. Corrigé en 1.0.1.
- **MacBook Pro M1 Pro, cask 1.0.0** : `brew install --cask fstormacq/tap/pulse` installe notre app, sans attribut de quarantaine (le `postflight_steps` marche), et lie `pulse` dans `/opt/homebrew/bin`. Au lancement, l'app a ouvert la fenêtre de mot de passe (« Pulse was updated to 1.0.0… 0.2.4 is running ») ; après saisie, le daemon est passé de 0.2.4 à 1.0.0, avec le profil (`balanced-copy`) et le rythme (5 s) conservés.
- **Limite notée** : le daemon cherche une nouvelle version 10 s après son démarrage, puis une fois par jour. Une release peut donc mettre jusqu'à 24 h à apparaître.

### 27/11/2026 : guide de contribution et flux par branches (ta demande)
- **Flux** : une branche par changement (`feat/…`, `fix/…`, `docs/…`), PR vers `dev` **en squash** avec un titre au format Conventional Commits, puis PR `dev` → `main` **en merge commit**, qui publie la release.
  - Le squash fait du titre de la PR le commit lu par `next-version.sh` et par les notes de version. Un workflow, **Pull request title** (`pr-title.yml`), vérifie ce titre.
  - Le merge commit vers `main` évite que `dev` et `main` divergent.
- **Docs** :
  - `CONTRIBUTING.md` : flux, titres, versions, contenu d'une PR, tests sur le matériel, style, bugs, releases et réglages du dépôt ;
  - `docs/ARCHITECTURE.md` : où se trouve le code de chaque partie, pourquoi, et comment faire les changements courants (commande CLI, méthode XPC, champ de config, preset, UI, identité, merge de smctl).
- **GitHub** : template de PR, templates d'issues (bug avec `pulse doctor`, idée), `CODEOWNERS`.
- **CI** : les PR lancent toujours la CI, même pour de la doc seule. Avec des checks obligatoires, un check qui ne démarre jamais bloquerait la PR. Les push gardent leur filtre.
- **Version** : ces commits sont en `docs:` et `ci:`, ils ne déclenchent pas de release à eux seuls. Ils partiront dans la 1.0.2, avec le `fix(app)` déjà sur `dev`.
- **À régler par toi sur GitHub** (détail dans `CONTRIBUTING.md` › Repository settings) : autoriser le squash (message par défaut : titre de la PR) et la suppression automatique des branches ; un ruleset sur `dev` ; sur le ruleset de `main`, garder seulement *Merge*.
