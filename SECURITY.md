# Sécurité

## Signaler une vulnérabilité

Merci de **ne pas ouvrir d'issue publique** pour une faille de sécurité. Utilisez le
[signalement privé de GitHub](https://github.com/ArnRso/amplo/security/advisories/new) :
seul le mainteneur voit le rapport, et un correctif peut être publié avant toute divulgation.

Précisez la version d'Amplo (menu › « Amplo x.y.z »), la version de macOS et, si possible,
les étapes pour reproduire le problème.

## Versions prises en charge

Seule la dernière version publiée reçoit des correctifs : les versions installées se mettent
à jour automatiquement (Sparkle).

## Points sensibles

- **Capture de l'audio système** : Amplo capte tout le son du Mac pour l'amplifier. Rien n'est
  enregistré sur disque ni envoyé sur le réseau.
- **Mises à jour** : chaque mise à jour est signée (EdDSA) ; l'app refuse toute archive dont la
  signature ne correspond pas à la clé publique intégrée (`SUPublicEDKey`).
