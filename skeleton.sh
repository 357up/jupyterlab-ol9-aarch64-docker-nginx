#!/usr/bin/bash

set -x

# install updates
sudo dnf update -y

# remove some preinstalled garbage
sudo dnf remove $(rpm -qa | grep cock) -y

# Install EPEL repo
sudo dnf install oracle-epel-release-el9

# Enable optional repos
sudo dnf config-manager --set-enabled ol9_addons
sudo dnf config-manager --set-enabled ol9_codeready_builder

# Install useful tools
sudo dnf install vim git htop ncdu ansible-core \
    policycoreutils-python-utils -y

# Install docker-ce
sudo dnf config-manager --add-repo \
    https://download.docker.com/linux/centos/docker-ce.repo  \
    && rpm --import https://download.docker.com/linux/centos/gpg \
    && sudo dnf install docker-ce docker-ce-cli containerd.io \
        docker-compose-plugin -y --nobest --allowerasing
    

# Enable and start docker service
sudo systemctl enable --now docker

# Add user `opc` to `docker` group
sudo usermod -a -G docker opc

# Allow ssh password authentication from docker subnets
# 1) add folowing block at the end of `/etc/ssh/sshd`
#    or in a new file at `/etc/ssh/sshd_config.d/`
# ```
# Match address 172.16.0.0/12
#    PasswordAuthentication yes
# ```
# 2) Reload ssh server config
sudo systemctl reload sshd
# 3) Set authentication password for `opc` user
[[ $(whoami) == "opc" ]] && passwd || sudo passwd opc

# TODO: CLONE project repo
mkdir -p /opt/jupyter/{notebooks,datasets}
