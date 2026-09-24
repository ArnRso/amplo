# Amplo

Booster de volume pour macOS : capte tout le son du système, lui applique un gain
(jusqu'à 300 %) et le renvoie vers la sortie active (haut-parleurs, jack, Bluetooth).

Repose sur les Core Audio Process Taps (macOS 14.2+), sans driver audio virtuel :
tap global muet excluant Amplo → aggregate device privé (sortie par défaut + tap) → IOProc.

## Installer

Télécharger le `.dmg` de la [dernière release](https://github.com/ArnRso/amplo/releases/latest), l'ouvrir et
glisser Amplo dans Applications. L'app n'est pas notarisée : au premier lancement, macOS la bloque ;
l'autoriser dans Réglages Système › Confidentialité et sécurité › « Ouvrir quand même ».

## Publier une version

Pousser un tag `v…` : GitHub Actions ([release.yml](.github/workflows/release.yml)) compile l'app,
produit le `.zip` et le `.dmg` (signés ad hoc) et crée la release avec les notes de
[Support/release-notes.md](Support/release-notes.md).

```sh
git tag v0.1.0
git push origin v0.1.0
```

En local, `scripts/package.sh 0.1.0` produit les mêmes fichiers dans `dist/`.
L'icône et le fond du `.dmg` sont générés par `swift scripts/make-artwork.swift`.

## Compiler et lancer

Avec Xcode : ouvrir `Amplo.xcodeproj` et lancer le schéma **Amplo** (⌘R).
Pour signer avec son Apple ID, choisir son équipe dans la cible Amplo → Signing & Capabilities.

En ligne de commande (Release, dans `build/Amplo.app`) :

```sh
./build.sh
open build/Amplo.app
```

Pour un usage quotidien, installer dans `/Applications` puis cocher « Ouvrir Amplo à la connexion »
dans le menu d'Amplo :

```sh
./build.sh --install
open /Applications/Amplo.app
```

Au premier démarrage, macOS demande l'autorisation d'enregistrer l'audio système
(Réglages Système → Confidentialité et sécurité → Enregistrement de l'écran et de l'audio système).
Sans équipe choisie, `build.sh` signe en ad hoc et la demande peut revenir après chaque compilation ; pour la réinitialiser :

```sh
tccutil reset AudioCapture com.arnrso.amplo
```

Journaux : `log stream --predicate 'subsystem == "com.arnrso.amplo"'`

## Avancement du POC

1. ✅ Capturer le son du système et le rejouer à 100 % sans altération
2. ✅ Appliquer un gain fixe de 150 % avec soft clipping
3. ✅ Rendre le gain modifiable via les paliers
4. ✅ Gérer le changement de sortie à chaud
5. ✅ Ajouter l'interface barre de menus (+ ouverture à la connexion)
6. ✅ Remplacer le soft clipping par un limiteur (avancée avant l'étape 4)
