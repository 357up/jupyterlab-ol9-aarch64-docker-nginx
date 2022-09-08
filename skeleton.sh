#!/usr/bin/bash

set -x

# System packages
## install updates
sudo dnf update -y

## remove some preinstalled garbage
sudo dnf remove -y $(rpm -qa | grep cock)

## Install EPEL repo
sudo dnf install -y oracle-epel-release-el9

## Enable optional repos
sudo dnf config-manager --set-enabled ol9_addons
sudo dnf config-manager --set-enabled ol9_codeready_builder

## Install useful tools
sudo dnf install -y vim git htop ncdu ansible-core \
    policycoreutils-python-utils netcat

# Install docker-ce
## Remove podman stack
sudo dnf group remove -y "Container Management"
## currently there is no docker-ce binary shipped for OL9_aarch64
## but Centos Stream 9 is the upstream of EL9 and OL9
## and docker-ce for S9 seems to be working just fine on OL9.
## But we will keep the docker-ce repo disabled by default just to
## be sure sure that a system update does not break it.
##
## In order to check if docker or any of it components have updates
## run `sudo dnf check-update --enablerepo=docker-ce-stable`
## and in order to update it/those
## `sudo dnf update --enablerepo=docker-ce-stable`
sudo dnf config-manager --add-repo \
    https://download.docker.com/linux/centos/docker-ce.repo &&
    sudo rpm --import https://download.docker.com/linux/centos/gpg &&
    sudo dnf config-manager --set-disabled docker-ce-stable &&
    sudo dnf install --enablerepo=docker-ce-stable -y --nobest --allowerasing \
        docker-ce docker-ce-cli containerd.io docker-compose-plugin

## Enable and start docker service
sudo systemctl enable --now docker

## Add user `opc` to `docker` group
## TODO: Skip if `opc` is already part of the `docker` group
sudo usermod -a -G docker opc

## Allow ssh password authentication from docker subnets
## 1) add folowing block at the end of `/etc/ssh/sshd`
##    or in a new file at `/etc/ssh/sshd_config.d/`
## ```
## Match address 172.16.0.0/12
##    PasswordAuthentication yes
## ```
## TODO: Other SSH settings
## 2) Reload ssh server config
sudo systemctl reload sshd
## 3) Set authentication password for `opc` user
sudo passwd -S opc | grep "Password locked" && sudo passwd opc

# JupyterLab
## App path
LAB_PATH="/opt/jupyter"
sudo mkdir -p $LAB_PATH/{notebooks,datasets}
sudo rsync -av --exclude ".git*" ./jupyter-docker/ $LAB_PATH
test -f "$LAB_PATH/.env" && sudo rm -f $LAB_PATH/.env.example ||
    sudo cp $LAB_PATH/.env.example $LAB_PATH/.env &&
    echo "Don't foget to update $($LAB_PATH/.env)"
sudo chmod 600 $LAB_PATH/.env
# TODO: Update access key and other .env variables
sudo chown -R opc: $LAB_PATH
sudo chown -R 1000:1000 $LAB_PATH/{notebooks,datasets}
# TODO: Build and spin up container

# Nginx
## Install
### Generate temporary self-signed certificate
test -L "/etc/ssl/private" || sudo ln -s /etc/pki/tls/private /etc/ssl/
(test -f "/etc/ssl/private/default.key" &&
    test -f "/etc/ssl/certs/default.pem") ||
    sudo openssl req -new -newkey rsa:2048 -days 3650 -nodes -x509 \
        -subj "/C=LV/ST=Riga/L=Riga/O=$(hostname)/CN=$(hostname)" \
        -keyout /etc/ssl/private/default.key \
        -out /etc/ssl/certs/default.pem
test -f "/etc/ssl/private/dhparam.pem" ||
    openssl dhparam -out /etc/ssl/private/dhparam.pem 4096
### Install Nginx package
sudo dnf install -y nginx nginx-all-modules
### Error pages
ERR_URL="https://github.com/denysvitali/nginx-error-pages/archive/refs/heads/master.zip"
ERR_PATH="nginx-error-pages-master"
ERR_TARGET_PATH="/usr/share/nginx/html/nginx-error-pages"
test -d "$ERR_TARGET_PATH" || (wget $ERR_URL -O $ERR_PATH.zip &&
    unzip $ERR_PATH -x \
        "$ERR_PATH/Makefile" \
        "$ERR_PATH/generate.py" \
        "$ERR_PATH/Dockerfile" \
        "$ERR_PATH/.dockerignore" \
        "$ERR_PATH/LICENSE" \
        "$ERR_PATH/README.md" \
        "$ERR_PATH/screenshots/*" \
        "$ERR_PATH/templates/*" \
        "$ERR_PATH/snippets/*" \
        "$ERR_PATH/conf/*" &&
    sudo mv $ERR_PATH $ERR_TARGET_PATH &&
    sudo ln -s $ERR_TARGET_PATH/_errors/main.css $ERR_TARGET_PATH)
### Configs
DEFAULTD="/etc/nginx/default.d"
CONFD="/etc/nginx/conf.d"
test -d "$DEFAULTD" || sudo mkdir -p "$DEFAULTD"
test -d "$CONFD" || sudo mkdir -p "$CONFD"
(test -f "$DEFAULTD/error-pages.conf" &&
    cmp -s ./nginx/error-pages.conf "$DEFAULTD/error-pages.conf") ||
    sudo cp ./nginx/error-pages.conf "$DEFAULTD/error-pages.conf"
(test -f "$DEFAULTD/ssl.conf" &&
    cmp -s ./nginx/ssl.conf "$DEFAULTD/ssl.conf") ||
    sudo cp ./nginx/ssl.conf "$DEFAULTD/ssl.conf"
(test -f "$CONFD/jupyterlab.conf" &&
    cmp -s ./nginx/jupyterlab.conf "$CONFD/jupyterlab.conf") ||
    sudo cp ./nginx/jupyterlab.conf "$CONFD/jupyterlab.conf"
### TODO: replace template values

## Systemd
sudo nginx -t &&
    sudo systemctl enable nginx

## Firewalld
(sudo firewall-cmd --permanent --zone=public --add-service=http &&
    sudo firewall-cmd --permanent --zone=public --add-service=https &&
    sudo firewall-cmd --reload) || true

## SELinux
sudo setsebool -P httpd_can_network_relay 1 || true
sudo setsebool -P httpd_can_network_connect 1 || true

# TODO: DNS
# TODO: Let's Encrypt
# TODO: Security List (FireWall)
# TODO: Cleanup
