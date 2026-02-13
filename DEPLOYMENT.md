# Deployment Guide

This repository includes Ansible playbooks to automate the deployment of the AzerothCore Docker stack to a remote server.

## Prerequisites

* **Ansible** installed on your local machine (`sudo apt install ansible` or `pip install ansible`).
* **SSH Access** to the remote machine (passwordless SSH key recommended).
* **Docker** installed on both local and remote machines.

## Configuration

1. **Inventory**: Edit `hosts.ini` to specify your remote host IP and user.

    ```ini
    [remote]
    192.168.86.24 ansible_user=peon
    ```

## Playbooks

### 1. Main Deployment (`deploy.yml`)

Deploys the server stack.

* Saves running Docker images locally.
* Transfers them to the remote host.
* Loads images and restarts the Docker stack.

**Usage:**

```bash
ansible-playbook -i hosts.ini deploy.yml
```

*(Add `-k` if you need to input an SSH password)*

### 2. Fix Git Configuration (`fix_git.yml`)

Ensures the remote directory is a valid git repository tracking the correct upstream.

* Initializes git if missing.
* Sets remote `origin` to `https://github.com/3shn/azerothcore-wotlk.git`.
* Resets local state to match `origin/wip`.

**Usage:**

```bash
ansible-playbook -i hosts.ini fix_git.yml
```

### 3. Update Realmlist (`update_realmlist.yml`)

Updates the database to advertise the correct IP address, fixing "Realm Loop" issues.

* Sets `address` in `acore_auth.realmlist` to the remote host's IP.
* Sets `localAddress` to `127.0.0.1`.

**Usage:**

```bash
ansible-playbook -i hosts.ini update_realmlist.yml
```

### 4. Verify Reachability (`verify_reachability.yml`)

Checks if the required ports are open and valid from your local machine.

* Checks ports: **3724** (Auth), **8085** (World), **7878** (SOAP).

**Usage:**

```bash
ansible-playbook -i hosts.ini verify_reachability.yml
```

### 5. Migrate Database (`migrate_db.yml`)

Transfers accounts and characters from your local machine to the remote server.

* **WARNING:** Overwrites remote `acore_auth` and `acore_characters` databases.
* Dumps local data -> Transfers -> Restores on remote.

**Usage:**

```bash
ansible-playbook -i hosts.ini migrate_db.yml
```

## Typical Workflow

1. **Deploy Code & Images:**

    ```bash
    ansible-playbook -i hosts.ini deploy.yml
    ```

2. **Fix Config/Realmlist** (if IP changed or fresh install):

    ```bash
    ansible-playbook -i hosts.ini update_realmlist.yml
    ```

3. **Migrate Data** (only if needed):

    ```bash
    ansible-playbook -i hosts.ini migrate_db.yml
    ```
