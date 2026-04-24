# ACME Flow — Infrastructure automatisée avec FreeIPA, Traefik et Authelia

> Projet d'automatisation d'infrastructure via Ansible.
> Déploiement d'un annuaire d'entreprise (FreeIPA), d'un reverse proxy sécurisé (Traefik)
> et d'un portail d'authentification SSO (Authelia), le tout sans aucune intervention manuelle.

---

## Table des matières

1. [Vue d'ensemble](#1-vue-densemble)
2. [Architecture](#2-architecture)
3. [Prérequis](#3-prérequis)
4. [Structure du projet](#4-structure-du-projet)
5. [Installation et déploiement](#5-installation-et-déploiement)
6. [Détail des playbooks](#6-détail-des-playbooks)
7. [Sauvegarde et restauration](#7-sauvegarde-et-restauration)
8. [Reproduire le projet](#8-reproduire-le-projet)

---

## 1. Vue d'ensemble

Ce projet automatise le déploiement d'une infrastructure d'identité et d'accès (IAM) complète pour une entreprise fictive, **ACME Corp**. L'objectif est de permettre aux employés d'accéder à une application web interne de façon sécurisée, en s'authentifiant avec un compte unique — principe du **SSO (Single Sign-On)**.

> **Note :** Ce repo contient uniquement l'infrastructure d'identité et d'accès.
> L'application métier déployée sur `serveur-app` est un composant séparé développé par une autre équipe.
> Elle doit être déployée indépendamment avant de pouvoir être accessible via le reverse proxy.

### Ce qui est entièrement automatisé

- ✅ Installation et configuration de **FreeIPA** (annuaire LDAP + Kerberos + DNS)
- ✅ Création de la **base utilisateurs et des groupes** (alice, bob, charlie, diane + comptes de service)
- ✅ Déploiement de **Traefik** en reverse proxy HTTPS avec certificat TLS
- ✅ Déploiement d'**Authelia** comme portail SSO, branché sur FreeIPA via LDAPS
- ✅ Configuration du **firewall** (firewalld) sur chaque serveur
- ✅ Synchronisation **NTP** via chrony
- ✅ Playbooks de **sauvegarde et restauration** FreeIPA *(voir note section 7)*

Aucune commande n'est lancée manuellement sur les serveurs cibles. Tout passe par Ansible depuis `serveur-admin`.

---

## 2. Architecture

### Plan d'adressage réseau

Le projet repose sur 3 VLANs distincts :

| VLAN | Réseau | Usage |
|------|--------|-------|
| VLAN Admin | 192.168.101.0/24 | Nœud de contrôle Ansible |
| VLAN Serveurs | 192.168.102.0/24 | IPA, App, Monitoring |
| VLAN DMZ | 192.168.103.0/24 | Reverse proxy (exposé) |

### Serveurs

| Serveur | IP | OS | RAM | Rôle |
|---|---|---|---|---|
| serveur-admin | 192.168.101.60 | Fedora | 2 Go | Nœud de contrôle Ansible |
| serveur-ipa | 192.168.102.60 | Fedora | **4 Go minimum** | Annuaire FreeIPA |
| serveur-app | 192.168.102.62 | Fedora | 2 Go | Application métier (Docker) |
| serveur-rproxy | 192.168.103.60 | Fedora | 2 Go | Reverse proxy Traefik + Authelia |
| serveur-monitoring | 192.168.102.63 | Fedora | 2 Go | Monitoring (si souhaitée, non automatisée dans ce projet pour l'instant mais listée pour évolution future)|

> ℹ️ `serveur-admin` n'est **pas** dans l'inventaire Ansible — c'est le nœud de contrôle depuis lequel tous les playbooks sont lancés. Il communique avec les autres serveurs via SSH avec la clé `~/.ssh/acme_ansible`.

### Schéma

```
  VLAN Admin (192.168.101.0/24)
  ┌──────────────────┐
  │  serveur-admin   │  → lance les playbooks Ansible
  │  192.168.101.60  │  → stocke les sauvegardes IPA
  └────────┬─────────┘
           │ SSH (ansible)
           ▼
  VLAN DMZ (192.168.103.0/24)
  ┌──────────────────────────────────────┐
  │         serveur-rproxy               │
  │         192.168.103.60               │
  │                                      │
  │  Traefik :443 ── flow.acme.lan       │
  │  Authelia :9091 (réseau Docker)      │
  │  Dashboard :8080 (127.0.0.1)         │
  └──────────────┬───────────────────────┘
                 │ forward-auth (LDAPS:636)
                 │ proxy vers app (HTTP:80)
                 ▼
  VLAN Serveurs (192.168.102.0/24)
  ┌──────────────────┐   ┌──────────────────┐   ┌────────────────────┐
  │  serveur-ipa     │   │  serveur-app     │   │ serveur-monitoring │
  │  192.168.102.60  │   │  192.168.102.62  │   │  192.168.102.63    │
  │                  │   │                  │   │                    │
  │  FreeIPA         │   │  Application     │   │  Monitoring        │
  │  LDAP/LDAPS      │   │  (Docker :80)    │   │                    │
  │  Kerberos        │   │  SQLite          │   │                    │
  │  DNS             │   │                  │   │                    │
  └──────────────────┘   └──────────────────┘   └────────────────────┘
```

### Flux d'authentification

```
Utilisateur → https://flow.acme.lan
    │
    ▼
Traefik (TLS, certificat auto-signé *.acme.lan)
    │
    ├─ /authelia → Authelia directement (pas de forward-auth)
    │
    └─ /* → middleware forward-auth
               │
               ▼
           Authelia vérifie la session
               │
               ├─ Session valide → proxy vers serveur-app:80
               │
               └─ Pas de session → redirect vers /authelia
                       │
                       ▼
                   Login/mdp → vérification LDAPS sur FreeIPA
                       │
                       └─ OK → cookie de session → accès à l'app
```

---

## 3. Prérequis

> ⚠️ **FreeIPA requiert impérativement 4 Go de RAM.** Le processus `pki-tomcatd` (autorité de certification Dogtag) est une JVM Java qui consomme ~800 Mo à elle seule. En dessous de 4 Go, l'installation échoue silencieusement.

### Sur serveur-admin

```bash
# Ansible
sudo dnf install ansible git -y

# Collections requises via le fichier inclus dans le projet
ansible-galaxy collection install -r ansible/requirements.yml
```

### Clé SSH

Une clé SSH dédiée doit être générée sur `serveur-admin` et déployée sur tous les serveurs cibles sous l'utilisateur `ansible` :

```bash
ssh-keygen -t ed25519 -f ~/.ssh/acme_ansible
ssh-copy-id -i ~/.ssh/acme_ansible.pub ansible@192.168.102.60   # serveur-ipa
ssh-copy-id -i ~/.ssh/acme_ansible.pub ansible@192.168.103.60   # serveur-rproxy
ssh-copy-id -i ~/.ssh/acme_ansible.pub ansible@192.168.102.62   # serveur-app
ssh-copy-id -i ~/.ssh/acme_ansible.pub ansible@192.168.102.63   # serveur-monitoring
```

### Application métier

L'application déployée sur `serveur-app` est un composant externe à ce repo. Elle doit :
- Être déployée via Docker et exposer le port `80`
- Être accessible depuis `serveur-rproxy` sur `192.168.102.62:80`
- Ne pas être exposée directement sur le réseau — seul Traefik y accède

### Résolution DNS locale

Sur chaque machine cliente souhaitant accéder à l'application, ajouter dans `/etc/hosts` :

```
192.168.103.60  flow.acme.lan
```

---

## 4. Structure du projet

```
ansible/
├── requirements.yml                     # Collections Ansible requises
├── .vault_pass                          # Mot de passe de chiffrement du vault (ne pas commiter)
│
├── inventory/
│   ├── hosts.yml                        # Inventaire des serveurs
│   ├── group_vars/
│   │   └── all/
│   │       ├── main.yml                 # Variables globales (domaine, IPs, NTP...)
│   │       ├── vault.yml                # Secrets chiffrés (ne pas commiter en clair)
│   │       └── vault.yml.example        # Template du vault à compléter
│   └── host_vars/
│       ├── serveur-ipa.yml              # Variables FreeIPA (domaine, groupes, utilisateurs)
│       └── serveur-rproxy.yml           # Variables reverse proxy (IPs, ports)
│
├── playbooks/
│   ├── ipa_install.yml                  # Installation et configuration FreeIPA
│   ├── rproxy_install.yml               # Déploiement Traefik + Authelia
│   ├── ipa_backup.yml                   # Sauvegarde FreeIPA
│   ├── ipa_restore.yml                  # Restauration FreeIPA
│   └── templates/
│       ├── chrony.conf.j2               # Configuration NTP
│       ├── traefik_static.yml.j2        # Config statique Traefik
│       ├── traefik_dynamic.yml.j2       # Routes et middlewares Traefik
│       ├── authelia_config.yml.j2       # Configuration Authelia
│       └── docker_compose_rproxy.yml.j2 # Stack Docker Compose
│
└── scripts/
    └── restore_ipa.sh                   # Script shell d'orchestration restauration
```

---

## 5. Installation et déploiement

### Étape 0 — Cloner le projet

```bash
git clone <url-du-repo> /opt/ansible
cd /opt/ansible/ansible
```

### Étape 1 — Créer le vault

```bash
cp inventory/group_vars/all/vault.yml.example \
   inventory/group_vars/all/vault.yml

# Éditer avec les vrais mots de passe
nano inventory/group_vars/all/vault.yml

# Générer les secrets Authelia (lancer 3 fois, une valeur par secret)
openssl rand -hex 32

# Chiffrer le vault
ansible-vault encrypt inventory/group_vars/all/vault.yml \
  --vault-password-file .vault_pass
```

Le vault doit contenir :

```yaml
vault_ipa_admin_password:      "..."   # Mot de passe admin FreeIPA (8+ chars)
vault_ipa_dm_password:         "..."   # Mot de passe Directory Manager (8+ chars)
vault_svc_authelia_password:   "..."   # Mot de passe compte de service LDAP
vault_authelia_jwt_secret:     "..."   # 64 caractères hex (openssl rand -hex 32)
vault_authelia_session_secret: "..."   # 64 caractères hex
vault_authelia_storage_key:    "..."   # 64 caractères hex
```

### Étape 2 — Déployer FreeIPA

```bash
ansible-playbook \
  -i inventory/hosts.yml \
  playbooks/ipa_install.yml \
  --vault-password-file .vault_pass
```

Durée estimée : **8 à 12 minutes** (l'installation de pki-tomcatd est longue).

### Étape 3 — Déployer le reverse proxy

```bash
ansible-playbook \
  -i inventory/hosts.yml \
  playbooks/rproxy_install.yml \
  --vault-password-file .vault_pass
```

Durée estimée : **2 à 3 minutes**.

### Étape 4 — Vérifier le déploiement

```bash
# FreeIPA
ansible -i inventory/hosts.yml ipa_servers -m command \
  -a "ipactl status" --vault-password-file .vault_pass -b

# Conteneurs sur serveur-rproxy
ansible -i inventory/hosts.yml rproxy_servers -m command \
  -a "docker ps" --vault-password-file .vault_pass -b
```

Puis tester dans un navigateur : `https://flow.acme.lan`

---

## 6. Détail des playbooks

### `ipa_install.yml` — Installation FreeIPA

Ce playbook orchestre l'installation complète de FreeIPA en trois phases.

**Play 1 — Préparation système :**
- Définition du hostname FQDN (obligatoire pour Kerberos)
- Configuration de `/etc/hosts`
- Mise à jour des métadonnées DNF
- Installation des prérequis système
- Configuration NTP via chrony (synchronisation avec `*.fr.pool.ntp.org`)
- Activation et configuration de firewalld
- Vérification SELinux en mode `enforcing`

**Play 2 — Installation FreeIPA :**

Utilise la collection officielle `freeipa.ansible_freeipa` qui appelle `ipa-server-install` avec tous les paramètres nécessaires. Configure automatiquement :
- L'annuaire LDAP (389-DS) sur les ports 389 et 636
- Le KDC Kerberos (ports 88 et 464)
- Le serveur DNS BIND intégré (port 53)
- L'autorité de certification Dogtag (pki-tomcatd)
- Le portail web IPA (`https://serveur-ipa.acme.lan/ipa/ui`)

**Play 3 — Configuration métier :**

Crée automatiquement toute la base utilisateurs et la structure organisationnelle :

| Utilisateur | Groupe | Rôle |
|---|---|---|
| alice | acme-users | Utilisateur standard |
| bob | acme-users | Utilisateur standard |
| charlie | acme-approvers | Approbateur |
| diane | acme-admins | Administrateur |
| svc-authelia | — | Compte de service LDAP (bind Authelia) |

> **Avantage clé :** zéro intervention manuelle sur l'interface web FreeIPA. Tous les utilisateurs, groupes et affiliations sont déclarés en YAML dans `host_vars/serveur-ipa.yml` et appliqués idempotentement — relancer le playbook ne crée pas de doublons.

---

### `rproxy_install.yml` — Reverse proxy Traefik + Authelia

Ce playbook déploie la couche d'accès sécurisé en 5 phases.

**Play 1 — Préparation système :**
- Installation de Docker CE et docker-compose-plugin depuis le dépôt officiel Docker
- Ouverture des ports 80 et 443 dans firewalld
- Création de l'arborescence `/opt/rproxy/`

**Play 2 — Certificat TLS :**

Génère un certificat auto-signé wildcard `*.acme.lan` valable 10 ans via OpenSSL. Ce certificat couvre `flow.acme.lan` et tout futur sous-domaine sans modification.

**Play 3 — Configuration Traefik :**

Déploie deux fichiers de configuration :
- **Config statique** (`traefik.yml`) : entrypoints HTTP/HTTPS, redirection automatique HTTP→HTTPS, provider fichier, dashboard local
- **Config dynamique** (`dynamic/routes.yml`) : routeurs, services, middleware forward-auth vers Authelia, headers de sécurité HTTP

La configuration dynamique est rechargée **à chaud** par Traefik sans redémarrage du conteneur.

**Play 4 — Configuration Authelia :**

Déploie la configuration complète depuis un template Jinja2 qui injecte automatiquement :
- Les secrets depuis le vault Ansible (jwt, session, storage)
- L'adresse LDAPS de FreeIPA (`ldaps://192.168.102.60:636`)
- Le DN de base et le DN du compte de service calculés depuis le nom de domaine
- La politique d'accès (one_factor pour `flow.acme.lan`)

**Play 5 — Docker Compose :**

Lance la stack via `community.docker.docker_compose_v2`. Les deux conteneurs (Traefik et Authelia) partagent un réseau Docker interne nommé `proxy` — Authelia n'est **jamais** exposé directement sur le réseau hôte.

> **Avantage clé :** `serveur-app` n'est accessible que depuis Traefik via son IP privée. Aucune route directe n'existe depuis l'extérieur. Un utilisateur non authentifié ne peut pas contourner Authelia.

---

## 7. Sauvegarde et restauration

> ⚠️ **Note :** Le playbook de restauration a été réalisé dans le cadre du projet mais n'a pas été intégralement testé en conditions réelles, faute de temps. Il constitue un axe d'amélioration identifié et une base de travail solide pour une mise en production.

### `ipa_backup.yml` — Sauvegarde FreeIPA (testé et fonctionnel)

Sauvegarde les données FreeIPA sans arrêter les services (`--online`).

**Ce qui est sauvegardé :**
- L'annuaire LDAP complet (utilisateurs, groupes, politiques)
- Les zones DNS
- Les certificats de l'autorité de certification
- La configuration Kerberos

**Fonctionnement :**
1. Lance `ipa-backup --data --online` sur `serveur-ipa`
2. Compresse le répertoire produit en `.tar.gz` horodaté
3. Rapatrie l'archive sur `serveur-admin` dans `/opt/backups/ipa/`
4. Purge les archives excédentaires (rétention : 7 dernières sauvegardes)
5. Configure un cron sur `serveur-admin` pour exécuter ce playbook chaque nuit à 2h00

```bash
# Lancer une sauvegarde manuelle
ansible-playbook \
  -i inventory/hosts.yml \
  playbooks/ipa_backup.yml \
  --vault-password-file .vault_pass

# Lister les sauvegardes disponibles
ls -lh /opt/backups/ipa/

# Vérifier le cron
crontab -l | grep ipa
```

### `ipa_restore.yml` — Restauration FreeIPA (encore à étoffer)

Restaure FreeIPA depuis la dernière sauvegarde disponible sur `serveur-admin`.

```bash
# Étape 1 — Réinstaller FreeIPA (infrastructure vide)
ansible-playbook \
  -i inventory/hosts.yml \
  playbooks/ipa_install.yml \
  --vault-password-file .vault_pass

# Étape 2 — Restaurer les données
ansible-playbook \
  -i inventory/hosts.yml \
  playbooks/ipa_restore.yml \
  --vault-password-file .vault_pass
```

---

## 8. Reproduire le projet

### Checklist complète

```
□ 5 VMs Fedora provisionnées avec les IPs et VLANs définis
□ Utilisateur "ansible" créé avec droits sudo sur chaque VM cible
□ Clé SSH ~/.ssh/acme_ansible générée et déployée depuis serveur-admin
□ Ansible et les collections installés sur serveur-admin
□ Repo cloné dans /opt/ansible
□ vault.yml créé, complété et chiffré
□ Application métier déployée sur serveur-app (port 80, accessible depuis rproxy)
□ Entrée flow.acme.lan dans /etc/hosts des clients
```

### Variables à adapter

Dans `inventory/group_vars/all/main.yml` :

```yaml
domain_name: "acme.lan"
realm_name:  "ACME.LAN"
dns_server_ip: "192.168.102.60"
ntp_servers:
  - "0.fr.pool.ntp.org"
  - "1.fr.pool.ntp.org"
```

Dans `inventory/host_vars/serveur-rproxy.yml` :

```yaml
app_ip:   "192.168.102.62"
app_port: "80"
```

### Commandes de déploiement complet

```bash
# 1. FreeIPA
ansible-playbook -i inventory/hosts.yml playbooks/ipa_install.yml \
  --vault-password-file .vault_pass

# 2. Reverse proxy
ansible-playbook -i inventory/hosts.yml playbooks/rproxy_install.yml \
  --vault-password-file .vault_pass

# 3. Première sauvegarde (optionnel)
ansible-playbook -i inventory/hosts.yml playbooks/ipa_backup.yml \
  --vault-password-file .vault_pass
```

---

## Accès aux interfaces

| Interface | URL | Identifiants |
|---|---|---|
| Application ACME | `https://flow.acme.lan` | alice / DemoAlice2025! |
| Portail Authelia | `https://flow.acme.lan/authelia` | — |
| Interface FreeIPA | `https://serveur-ipa.acme.lan/ipa/ui` | admin / (vault) |
| Dashboard Traefik | `http://localhost:8080` *(via tunnel SSH)* | — |

```bash
# Tunnel SSH pour accéder au dashboard Traefik
ssh -L 8080:127.0.0.1:8080 ansible@192.168.103.60
# Puis ouvrir http://localhost:8080
```

> Le certificat TLS est auto-signé — accepter l'exception de sécurité dans le navigateur,
> ou importer `/opt/rproxy/traefik/certs/acme.lan.crt` comme CA de confiance sur les clients.

---

*Projet réalisé dans le cadre d'un devoir d'automatisation d'infrastructure.*