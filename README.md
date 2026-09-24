# Amplo

Booster de volume pour macOS : capte tout le son du système, lui applique un gain
(jusqu'à 300 %) et le renvoie vers la sortie active (haut-parleurs, jack, Bluetooth).

Repose sur les Core Audio Process Taps (macOS 14.2+), sans driver audio virtuel :
tap global muet excluant Amplo → aggregate device privé (sortie par défaut + tap) → IOProc.

## Compiler et lancer

Les Command Line Tools suffisent (Xcode non requis) :

```sh
./build.sh
open build/Amplo.app
```

Au premier démarrage, macOS demande l'autorisation d'enregistrer l'audio système
(Réglages Système → Confidentialité et sécurité → Enregistrement de l'écran et de l'audio système).
Avec une signature ad hoc, la demande peut revenir après chaque compilation ; pour la réinitialiser :

```sh
tccutil reset AudioCapture com.amplo.Amplo
```

Journaux : `log stream --predicate 'subsystem == "com.amplo.Amplo"'`

## Avancement du POC

1. ✅ Capturer le son du système et le rejouer à 100 % sans altération
2. ✅ Appliquer un gain fixe de 150 % avec soft clipping
3. Rendre le gain modifiable via les paliers
4. Gérer le changement de sortie à chaud
5. Ajouter l'interface barre de menus
6. Remplacer le soft clipping par un limiteur
