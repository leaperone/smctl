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
| Mémoire après ouverture des vues | ~50 Mo (SwiftUI et Charts restent chargés) | à surveiller |

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
- On part de `CurvesChart`. `chartOverlay` et `ChartProxy` convertissent les coordonnées en (°C, %) ; `DragGesture` pilote les poignées (`PointMark` agrandis au survol, curseur adapté).
- Forme : 2 poignées d'extrémité, plus une poignée de raideur au milieu de la rampe qu'on glisse verticalement (avec un curseur en complément, pour l'accessibilité).
- Paliers : un réglage du nombre de paliers. Points : on glisse chaque point, un double-clic en ajoute un, la touche Suppr retire le point sélectionné.
- **Bascule %/RPM** pour l'axe Y, à partir de la plage F0Mn/F0Mx lue dans la télémétrie. Sans ventilateur, seul le % est proposé.
- VoiceOver : chaque poignée est un élément ajustable (incrément d'1 °C ou d'1 %).
- Performance : pendant un glisser, on recalcule environ 140 points par image. Si ce n'est pas fluide, on réduit la résolution pendant le glisser.

### 3d. Aperçu live
- Une ligne verticale indique la température lissée actuelle, avec un point sur la courbe : « 54 °C → 12 % (1 450 RPM) ». On ajoute aussi la vitesse réelle du ventilateur.
- Les presets apparaissent en courbes « fantômes » pâles, pour se repérer.
- Un panneau de réponse indique le temps pour passer du minimum au maximum avec les vitesses de montée choisies, et l'effet de l'hystérésis.
- Option à décider à cette étape : **« Essayer 60 s »**, qui active le brouillon temporairement puis revient au profil précédent. Il faut un petit ajout au daemon (activation temporaire avec retour automatique, garde-fou toujours actif). Sinon, on se contente d'« Enregistrer » et « Enregistrer et activer ».

### 3e. Enregistrement et robustesse
- « Enregistrer », « Enregistrer et activer », « Annuler les modifications ». À la fermeture ou au changement de courbe avec des modifications en cours : proposer d'enregistrer, d'ignorer ou d'annuler.
- Les erreurs du daemon (validation, daemon absent) s'affichent dans l'éditeur, et le brouillon est conservé.
- Si la config change ailleurs pendant l'édition (SSH, `pulse fan curve set`) : avertissement « modifiée ailleurs », avec rechargement ou écrasement.
- C'est l'occasion de traiter la raideur du preset Performance : en dupliquant le preset, on obtient une version plus douce entre 60 et 63 °C. On ne change pas le preset sans ton accord.

### 3f. Validation de la phase 3
- Captures de l'éditeur dans chaque mode (forme, paliers, points), en clair et en sombre.
- PulseBench : éditeur ouvert, éditeur refermé, plus un glisser simulé.
- Test réel : créer « night » dans l'app, l'activer, vérifier avec `pulse status` et `pulse fan curve show night` (en SSH), modifier en SSH et voir l'app se mettre à jour, puis supprimer.
- Mise à jour du README (capture de l'éditeur) et de la feuille de route.

---

## Phase 4 : finitions

### 4a. Notification du garde-fou
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
