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

### 4c. Déclencheurs (horaire de nuit, etc.)
- **Décision à prendre à cette étape**. Recommandation : dans le **daemon** (`[[fan.schedules]]` dans le TOML), pour que les déclencheurs fonctionnent sans l'app et soient visibles en SSH. Par exemple `{ profile = "silent", from = "22:00", to = "07:00", days = "all" }`.
- Règles : un choix manuel l'emporte jusqu'au prochain changement d'horaire ; le garde-fou l'emporte toujours ; passage à l'heure d'été et réveil de veille testés.
- Autres déclencheurs possibles, à valider avec toi : sur batterie ou sur secteur (MacBook), écran éteint.
- CLI (`pulse fan schedule list|set|delete`), XPC et une section « Horaires » dans l'onglet Courbes.

### 4d. Validation sur MacBook (nécessite ton MacBook)
- Chemin `Ftst` (les MacBook Pro M-series ont besoin du déblocage d'écriture), fonctions batterie de smctl, modèle sans ventilateur (MacBook Air : surveillance seule, éléments liés au ventilateur masqués).
- Commande de diagnostic `pulse doctor` à créer : elle produira un rapport à me transmettre.

### 4e. Campagne de tests matériels (§4 de la feuille de route)
- Installation et désinstallation, changement de profil (app et SSH), veille et réveil, `kill -9 pulsed`, fermeture de l'app, charge soutenue, garde-fou provoqué, outil concurrent, redémarrage.
- Je prépare un script qui guide chaque test et enregistre les résultats. Les étapes avec `sudo` ou une action physique sont faites par toi.

### 4f. Préparation de la version 1.0
- Profiler `pulsed` (objectif < 0,2 %) et viser < 0,1 % pour l'app au repos.
- CI : ajout de la compilation et des tests de `App/` si les runners proposent Xcode 26.
- Version 1.0, notes de version, archive de `Pulse.app`. Signature : ad hoc ou compte développeur, à décider.
- PR des améliorations génériques vers smctl (courbes en %, formes, zone morte) : à décider (« on verra »). Le fork rend ces PR triviales.

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
- `scripts/test-safety-notification.sh` (avec `sudo`) : abaisse le plafond à 45 °C pour déclencher le garde-fou, attend, puis restaure la config, même après Ctrl-C.
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
