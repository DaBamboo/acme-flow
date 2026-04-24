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

### Ce qui est entièrement automatisé

- ✅ Installation et configuration de **FreeIPA** (annuaire LDAP + Kerberos + DNS)
- ✅ Création de la **base utilisateurs et des groupes** (alice, bob, charlie, diane + comptes de service)
- ✅ Déploiement de **Traefik** en reverse proxy HTTPS avec certificat TLS
- ✅ Déploiement d'**Authelia** comme portail SSO, branché sur FreeIPA via LDAPS
- ✅ Configuration du **firewall** (firewalld) sur chaque serveur
- ✅ Synchronisation **NTP** via chrony
- ✅ **Sauvegarde automatique** quotidienne de FreeIPA avec rétention sur 7 jours
- ✅ **Restauration** complète de FreeIPA depuis une archive

Aucune commande n'est lancée manuellement sur les serveurs cibles. Tout passe par Ansible depuis `serveur-admin`.

---

## 2. Architecture

```
┌─────────────────────────────────────────────────────────┐
│                     Réseau interne                       │
│                                                         │
│  ┌──────────────┐      ┌──────────────────────────────┐ │
│  │ serveur-admin│      │       serveur-rproxy          │ │
│  │ 192.168.102.5│      │      192.168.103.60           │ │
│  │              │      │                              │ │
│  │  Ansible     │      │  Traefik :443 / :80          │ │
│  │  Git         │─────▶│  Authelia :9091 (interne)    │ │
│  │  Vault       │      │  Dashboard :8080 (local)     │ │
│  └──────────────┘      └──────────────┬───────────────┘ │
│                                       │ forward-auth     │
│  ┌──────────────┐                     │                  │
│  │ serveur-ipa  │◀────────────────────┘ LDAPS:636        │
│  │192.168.102.60│                                        │
│  │              │                                        │
│  │  FreeIPA     │      ┌──────────────────────────────┐ │
│  │  LDAP :389   │      │       serveur-app             │ │
│  │  LDAPS :636  │      │      192.168.102.62           │ │
│  │  Kerberos    │      │                              │ │
│  │  DNS :53     │      │  Application :80 (Docker)    │ │
│  └──────────────┘      │  SQLite                      │ │
│                        └──────────────────────────────┘ │
└─────────────────────────────────────────────────────────┘
```

### Flux d'authentification

```
Utilisateur → https://flow.acme.lan
    │
    ▼
Traefik (reverse proxy TLS)
    │
    ├─ /authelia → Authelia (portail de login)
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

### Machines virtuelles

| Serveur | IP | OS | RAM | CPU | Rôle |
|---|---|---|---|---|---|
| serveur-admin | 192.168.102.5 | Fedora | 2 Go | 2 | Nœud de contrôle Ansible |
| serveur-ipa | 192.168.102.60 | Fedora | **4 Go minimum** | 2 | Annuaire FreeIPA |
| serveur-rproxy | 192.168.103.60 | Fedora | 2 Go | 2 | Reverse proxy |
| serveur-app | 192.168.102.62 | Fedora | 2 Go | 2 | Application métier |

> ⚠️ **FreeIPA requiert impérativement 4 Go de RAM.** Le processus `pki-tomcatd` (autorité de certification Dogtag) est une JVM Java qui consomme ~800 Mo à elle seule. En dessous de 4 Go, l'installation échoue silencieusement.

### Sur serveur-admin

```bash
# Ansible
sudo dnf install ansible -y

# Collections requises
ansible-galaxy collection install freeipa.ansible_freeipa
ansible-galaxy collection install community.docker
ansible-galaxy collection install ansible.posix

# Git
sudo dnf install git -y
```

### Clés SSH

La clé SSH de `serveur-admin` doit être déployée sur tous les serveurs cibles :

```bash
ssh-keygen -t ed25519 -f ~/.ssh/id_ansible
ssh-copy-id -i ~/.ssh/id_ansible.pub admin@192.168.102.60   # serveur-ipa
ssh-copy-id -i ~/.ssh/id_ansible.pub admin@192.168.103.60   # serveur-rproxy
ssh-copy-id -i ~/.ssh/id_ansible.pub admin@192.168.102.62   # serveur-app
```

### Résolution DNS locale

Sur chaque machine cliente souhaitant accéder à l'application, ajouter dans `/etc/hosts` :

```
192.168.103.60  flow.acme.lan
```

---

## 4. Structure du projet

```
ansible/
├── ansible.cfg                          # Configuration Ansible (inventory par défaut, etc.)
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
│       ├── serveur-ipa.yml              # Variables spécifiques à FreeIPA
│       └── serveur-rproxy.yml           # Variables spécifiques au reverse proxy
│
└── playbooks/
    ├── ipa_install.yml                  # Installation et configuration FreeIPA
    ├── rproxy_install.yml               # Déploiement Traefik + Authelia
    ├── ipa_backup.yml                   # Sauvegarde FreeIPA
    ├── ipa_restore.yml                  # Restauration FreeIPA
    └── templates/
        ├── traefik_static.yml.j2        # Config statique Traefik
        ├── traefik_dynamic.yml.j2       # Routes et middlewares Traefik
        ├── authelia_config.yml.j2       # Configuration Authelia
        └── docker_compose_rproxy.yml.j2 # Stack Docker Compose
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

# Générer les secrets Authelia (lancer 3 fois)
openssl rand -hex 32

# Chiffrer le vault
ansible-vault encrypt inventory/group_vars/all/vault.yml \
  --vault-password-file .vault_pass
```

Le vault doit contenir :

```yaml
vault_ipa_admin_password:      "..."   # Mot de passe admin FreeIPA
vault_ipa_dm_password:         "..."   # Mot de passe Directory Manager
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

Ce playbook orchestre l'installation complète de FreeIPA en deux phases.

**Play 1 — Préparation système :**
- Définition du hostname FQDN (obligatoire pour Kerberos)
- Configuration de `/etc/hosts`
- Mise à jour des métadonnées DNF
- Installation des prérequis système
- Configuration NTP via chrony (synchronisation avec `*.fr.pool.ntp.org`)
- Activation firewalld

**Play 2 — Installation FreeIPA :**

Utilise la collection officielle `freeipa.ansible_freeipa` qui appelle `ipa-server-install` avec tous les paramètres nécessaires. Configure automatiquement :
- L'annuaire LDAP (389-DS)
- Le KDC Kerberos
- Le serveur DNS BIND intégré
- L'autorité de certification (Dogtag CA / pki-tomcatd)
- Le portail web IPA (`https://serveur-ipa.acme.lan/ipa/ui`)

**Play 3 — Configuration métier :**

Crée automatiquement toute la base utilisateurs et la structure organisationnelle :

| Utilisateur | Groupe | Rôle |
|---|---|---|
| alice | acme-users | Utilisateur standard |
| bob | acme-users | Utilisateur standard |
| charlie | acme-approvers | Approbateur |
| diane | acme-admins | Administrateur |
| svc-authelia | — | Compte de service LDAP |

> **Avantage clé :** zéro intervention manuelle sur l'interface web FreeIPA. Tous les utilisateurs, groupes et affiliations sont déclarés en YAML et appliqués idempotentement — relancer le playbook ne crée pas de doublons.

---

### `rproxy_install.yml` — Reverse proxy Traefik + Authelia

Ce playbook déploie la couche d'accès sécurisé en 5 phases.

**Play 1 — Préparation système :**
- Installation de Docker CE et docker-compose-plugin
- Ouverture des ports 80 et 443 dans firewalld
- Création de l'arborescence `/opt/rproxy/`

**Play 2 — Certificat TLS :**

Génère un certificat auto-signé wildcard `*.acme.lan` valable 10 ans via OpenSSL. Ce certificat couvre `flow.acme.lan` et tout futur sous-domaine sans modification.

**Play 3 — Configuration Traefik :**

Déploie deux fichiers de configuration :
- **Config statique** (`traefik.yml`) : entrypoints HTTP/HTTPS, redirection automatique HTTP→HTTPS, provider fichier, dashboard
- **Config dynamique** (`dynamic/routes.yml`) : routeurs, services, middleware forward-auth

La configuration dynamique est rechargée **à chaud** par Traefik sans redémarrage du conteneur.

**Play 4 — Configuration Authelia :**

Déploie la configuration complète depuis un template Jinja2 qui injecte automatiquement :
- Les secrets depuis le vault Ansible
- L'adresse LDAPS de FreeIPA
- Le DN de base calculé depuis le nom de domaine
- Le DN du compte de service

**Play 5 — Docker Compose :**

Lance la stack via `community.docker.docker_compose_v2`. Les deux conteneurs partagent un réseau Docker interne nommé `proxy` — Authelia n'est **jamais** exposé directement sur le réseau hôte, seul Traefik l'est.

> **Avantage clé :** `serveur-app` n'est accessible que depuis Traefik. Aucune route directe n'existe depuis l'extérieur. Un utilisateur non authentifié ne peut pas contourner Authelia.

---

### `ipa_backup.yml` — Sauvegarde FreeIPA

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
5. Configure un cron sur `serveur-admin` pour exécuter automatiquement ce playbook chaque nuit à 2h00

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

---

### `ipa_restore.yml` — Restauration FreeIPA

Restaure FreeIPA depuis la dernière sauvegarde disponible sur `serveur-admin`.

**Scénario d'usage :** perte de données, corruption de l'annuaire, migration vers un nouveau serveur.

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

Durée totale estimée : **10 à 15 minutes**.

---

## 7. Sauvegarde et restauration

### Politique de rétention

Les 7 dernières sauvegardes sont conservées sur `serveur-admin`. Les archives plus anciennes sont supprimées automatiquement à chaque nouvelle sauvegarde.

### Vérifier l'intégrité d'une archive

```bash
# Lister le contenu sans extraire
tar -tzf /opt/backups/ipa/ipa-data-<date>.tar.gz | head -20
```

### Restauration d'urgence

En cas de perte complète de `serveur-ipa` :

1. Provisionner une nouvelle VM Fedora avec la même IP (`192.168.102.60`)
2. Déployer la clé SSH depuis `serveur-admin`
3. Lancer les deux playbooks de restauration ci-dessus

---

## 8. Reproduire le projet

### Checklist complète

```
□ 4 VMs Fedora provisionnées avec les IPs définies
□ Clés SSH déployées depuis serveur-admin vers les 3 autres serveurs
□ Ansible et les collections installés sur serveur-admin
□ Repo cloné dans /opt/ansible/ansible
□ vault.yml créé, complété et chiffré
□ Entrée flow.acme.lan dans /etc/hosts des clients
```

### Variables à adapter

Dans `inventory/group_vars/all/main.yml` :

```yaml
domain_name: "acme.lan"        # Votre domaine
ipa_realm:   "ACME.LAN"        # En majuscules
ipa_ip:      "192.168.102.60"  # IP de serveur-ipa
ntp_servers:                   # Serveurs NTP de votre région
  - "0.fr.pool.ntp.org"
  - "1.fr.pool.ntp.org"
```

Dans `inventory/host_vars/serveur-rproxy.yml` :

```yaml
app_ip:   "192.168.102.62"  # IP de serveur-app
app_port: "80"              # Port exposé par l'application
```

### Commandes de déploiement complet

```bash
# 1. FreeIPA
ansible-playbook -i inventory/hosts.yml playbooks/ipa_install.yml \
  --vault-password-file .vault_pass

# 2. Reverse proxy
ansible-playbook -i inventory/hosts.yml playbooks/rproxy_install.yml \
  --vault-password-file .vault_pass

# 3. Première sauvegarde
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
| Dashboard Traefik | `http://localhost:8080` (via tunnel SSH) | — |

> Le certificat TLS est auto-signé — accepter l'exception de sécurité dans le navigateur ou importer `acme.lan.crt` comme CA de confiance.

---

*Projet réalisé dans le cadre d'un devoir d'automatisation d'infrastructure.*