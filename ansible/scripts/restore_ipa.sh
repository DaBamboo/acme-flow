#!/usr/bin/env bash
# scripts/restore_ipa.sh
#
# Script de restauration FreeIPA pour la démo jury.
#
# Scénario : le jury demande "désinstallez FreeIPA et ses données, puis restaurez-les".
# Ce script orchestre la séquence complète en affichant une progression claire.
#
# DURÉE ATTENDUE : 5-8 minutes
#
# UTILISATION depuis serveur-admin :
#   chmod +x scripts/restore_ipa.sh
#   ./scripts/restore_ipa.sh
#
# PRÉREQUIS :
#   - ansible-playbook installé sur serveur-admin
#   - Vault Ansible accessible (fichier .vault_pass dans le répertoire du projet)
#   - Au moins une sauvegarde dans /opt/backups/ipa/

set -euo pipefail

# ── Configuration ────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
INVENTORY="$PROJECT_DIR/inventory/hosts.yml"
VAULT_PASS="$PROJECT_DIR/.vault_pass"
LOG_FILE="/tmp/ipa-restore-$(date +%Y%m%d-%H%M%S).log"

# ── Couleurs pour l'affichage ─────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'  # No Color

# ── Fonctions utilitaires ─────────────────────────────────────────────────────
log_step() { echo -e "\n${BLUE}▶ $1${NC}"; }
log_ok()   { echo -e "  ${GREEN}✔ $1${NC}"; }
log_warn() { echo -e "  ${YELLOW}⚠ $1${NC}"; }
log_err()  { echo -e "  ${RED}✘ $1${NC}"; }

print_timer() {
    local elapsed=$(( $(date +%s) - START_TIME ))
    echo -e "  ⏱  Temps écoulé : ${elapsed}s"
}

# ── Vérifications préliminaires ───────────────────────────────────────────────
START_TIME=$(date +%s)

echo ""
echo "═══════════════════════════════════════════════════"
echo "  RESTAURATION FREEIPA — ACME Corp"
echo "  $(date '+%Y-%m-%d %H:%M:%S')"
echo "═══════════════════════════════════════════════════"
echo ""

log_step "Vérification des prérequis"

if ! command -v ansible-playbook &>/dev/null; then
    log_err "ansible-playbook introuvable. Installer Ansible sur serveur-admin."
    exit 1
fi
log_ok "ansible-playbook disponible"

if [[ ! -f "$VAULT_PASS" ]]; then
    log_err "Fichier .vault_pass introuvable dans $PROJECT_DIR"
    log_warn "Créer le fichier avec le mot de passe Ansible Vault"
    exit 1
fi
log_ok "Vault password file trouvé"

BACKUP_COUNT=$(find /opt/backups/ipa -name "ipa-data-*.tar.gz" 2>/dev/null | wc -l)
if [[ "$BACKUP_COUNT" -eq 0 ]]; then
    log_err "Aucune sauvegarde trouvée dans /opt/backups/ipa/"
    exit 1
fi
LATEST_BACKUP=$(find /opt/backups/ipa -name "ipa-data-*.tar.gz" | sort | tail -1)
log_ok "$BACKUP_COUNT sauvegarde(s) disponible(s)"
log_ok "Dernière sauvegarde : $(basename "$LATEST_BACKUP")"

# ── Confirmation ──────────────────────────────────────────────────────────────
echo ""
echo "  Cette opération va :"
echo "    1. Désinstaller FreeIPA et SUPPRIMER toutes ses données"
echo "    2. Réinstaller FreeIPA depuis zéro"
echo "    3. Restaurer les données depuis : $(basename "$LATEST_BACKUP")"
echo ""
read -rp "  Continuer ? [oui/non] : " CONFIRM
if [[ "$CONFIRM" != "oui" ]]; then
    echo "  Annulé."
    exit 0
fi

# ── Étape 1 : Désinstallation ─────────────────────────────────────────────────
log_step "Étape 1/3 — Désinstallation de FreeIPA"
echo "  Logs détaillés dans : $LOG_FILE"

ansible-playbook \
    -i "$INVENTORY" \
    --vault-password-file "$VAULT_PASS" \
    -e "ipa_action=uninstall" \
    "$PROJECT_DIR/playbooks/ipa_uninstall.yml" \
    | tee -a "$LOG_FILE" \
    | grep -E "(TASK|ok:|changed:|failed:|PLAY RECAP)"

print_timer
log_ok "FreeIPA désinstallé"

# ── Étape 2 : Réinstallation ──────────────────────────────────────────────────
log_step "Étape 2/3 — Réinstallation de FreeIPA (≈ 3-5 min)"

ansible-playbook \
    -i "$INVENTORY" \
    --vault-password-file "$VAULT_PASS" \
    --tags "ipa_install" \
    "$PROJECT_DIR/playbooks/ipa_install.yml" \
    | tee -a "$LOG_FILE" \
    | grep -E "(TASK|ok:|changed:|failed:|PLAY RECAP)"

print_timer
log_ok "FreeIPA réinstallé"

# ── Étape 3 : Restauration des données ───────────────────────────────────────
log_step "Étape 3/3 — Restauration des données"

ansible-playbook \
    -i "$INVENTORY" \
    --vault-password-file "$VAULT_PASS" \
    -e "restore_backup_path=$LATEST_BACKUP" \
    "$PROJECT_DIR/playbooks/ipa_restore_data.yml" \
    | tee -a "$LOG_FILE" \
    | grep -E "(TASK|ok:|changed:|failed:|PLAY RECAP)"

print_timer
log_ok "Données restaurées depuis $(basename "$LATEST_BACKUP")"

# ── Vérification finale ───────────────────────────────────────────────────────
log_step "Vérification de l'état de FreeIPA"

TOTAL_TIME=$(( $(date +%s) - START_TIME ))

# Test basique : le portail web IPA répond
HTTP_STATUS=$(curl -sk -o /dev/null -w "%{http_code}" https://serveur-ipa.acme.lan/ipa/ui 2>/dev/null || echo "000")
if [[ "$HTTP_STATUS" == "200" ]] || [[ "$HTTP_STATUS" == "301" ]]; then
    log_ok "Portail web IPA répond (HTTP $HTTP_STATUS)"
else
    log_warn "Portail web IPA inaccessible (HTTP $HTTP_STATUS) — vérifier dans 30s"
fi

echo ""
echo "═══════════════════════════════════════════════════"
echo -e "  ${GREEN}✅  RESTAURATION TERMINÉE${NC}"
echo "  Durée totale : ${TOTAL_TIME}s"
echo "  Logs complets : $LOG_FILE"
echo ""
echo "  Portail FreeIPA : https://serveur-ipa.acme.lan/ipa/ui"
echo "  Vérifier avec  : kinit admin && ipa user-find"
echo "═══════════════════════════════════════════════════"
