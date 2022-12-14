#!/usr/bin/env bash
#
# Usage:
#   ./setup.sh ( [--stages=all] | --stages=[all,]<-stage>... | --stages=[-all,]<stage>... ) [options]
#   ./setup.sh -h | --help
#   ./setup.sh -l | --list-stages
#   ./setup.sh --version
#
# Options:
#   -u,--system-user=<user>             Application user [default: opc]
#   --system-user-password=<pw>         Application user password [default: <empty>]
#   --jupyterlab-password=<pw>          JupyterLab password [default: <empty>]
#   -d,--domain=<domain>                Application domain [default: $DOMAIN]
#   -e,--email=<email>                  Email address to send acme.sh notifications to [default: $EMAIL]
#   -p,--lab-path=<path>                Path to lab directory [default: /opt/jupyter]
#
# Examples:
#   ./setup.sh --stages=-dns,-cert -p /opt/jupyter -u opc -e $EMAIL
#   ./setup.sh --stages=-all,lab -p /opt/jupyter --jupyterlab-password=TOP-SECRET

#set -x
set -e

# TODO: Create motd

# GLOBALS
version='0.8.1beta'
IP=$(curl -sSL https://ipv4.icanhazip.com)
NGINX="/etc/nginx"
DEFAULTD="$NGINX/default.d"
CONFD="$NGINX/conf.d"

declare -A ALL_STAGES=(
    ["prep"]=0
    ["docker"]=1
    ["jupyter"]=2
    ["build"]=3
    ["web"]=4
    ["ingress"]=5
    ["dns"]=6
    ["cert"]=7
    ["cleanup"]=8)

# HELPER FUNCTIONS

function splitStages() {
    INPUT=$(awk -F"," '{for(i=1;i<=NF;i++){printf "%s\n", $i}}' <<<"${myargs[$a]}")
    while read -r line; do
        if [[ ! $line =~ ^-?all$ ]]; then
            STAGES+=("$line")
        fi
    done <<<"$INPUT"
}

# STAGES

function prep() {
    # Set authentication password for the system user
    if [[ "$USER_PASSWORD" != "<empty>" ]]; then
        echo "$USER:$USER_PASSWORD" | sudo chpasswd
    else
        if sudo passwd -S "$USER" | grep -q "Password locked"; then
            echo "Password for $USER wasn't specified. Enter the password now"
            sudo passwd "$USER"
        fi
    fi

    # System packages
    ## remove some preinstalled garbage
    sudo dnf remove -y "$(rpm -qa | grep cock)"

    ## install updates
    sudo dnf update -y

    ## Install EPEL repo
    sudo dnf install -y oracle-epel-release-el9

    ## Enable optional repos
    sudo dnf config-manager --set-enabled \
        {ol9_addons,ol9_codeready_builder,ol9_developer,ol9_developer_EPEL}

    ## Install useful tools
    sudo dnf install -y vim git htop ncdu ansible-core \
        policycoreutils-python-utils netcat bind-utils \
        wget curl unzip jq python3-pip figlet

    ## Install "Oh my BASH!"
    if [[ ! -d /usr/local/share/oh-my-bash ]]; then
        sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/ohmybash/oh-my-bash/master/tools/install.sh)" --unattended --prefix=/usr/local
        sudo sed -i '47s|HIST_STAMPS=.*|HIST_STAMPS="dd/MM/yyyy"|' /usr/local/share/oh-my-bash/bashrc
        sudo sed -i '48 i THEME_CLOCK_FORMAT="%H:%M:%S"' /usr/local/share/oh-my-bash/bashrc    
        cp /usr/local/share/oh-my-bash/bashrc ~/.bashrc
        sudo cp /usr/local/share/oh-my-bash/bashrc /root/.bashrc
        sudo sed -i 's/OSH_THEME=".*"/OSH_THEME="axin"/' /root/.bashrc
        source ~/.bashrc
    fi

    ## Install MOTD
    ### Stylish hostname
    sudo cp ./etc/motd.d/00hostname /etc/motd.d/
    contents="\e[32m$(figlet -t -k "$(hostname)")\e[0m"
    echo -e "$contents" | sudo tee /etc/motd.d/00hostname
    ### Common commands
    sudo cp ./etc/motd.d/97commands /etc/motd.d/
    
    ## Print MOTD on login
    sudo sed -i 's/^#PrintMotd.*/PrintMotd yes/' /etc/ssh/sshd_config
    sudo systemctl reload sshd
    
    ## Install cheat
    curl -sSL https://github.com/cheat/cheat/releases/latest/download/cheat-linux-arm64.gz | gunzip -c > ./cheat
    chmod +x ./cheat
    if [[ -x /usr/local/bin/cheat ]]; then
        if [[ $(./cheat -v) != $(/usr/local/bin/cheat -v) ]]; then
            sudo mv ./cheat /usr/local/bin/cheat
        else
            rm ./cheat
        fi
    else
        sudo mv ./cheat /usr/local/bin/cheat
        mkdir -p ~/.config/cheat && cheat --init > ~/.config/cheat/conf.yml
        sed -i "s#PAGER_PATH#less -FRX#g" ~/.config/cheat/conf.yml
        mkdir -p ~/.config/cheat/cheatsheets/{community,personal}
        git clone https://github.com/cheat/cheatsheets.git ~/.config/cheat/cheatsheets/community
    fi

}

function docker() {
    # Install docker-ce
    ## Remove podman stack
    sudo dnf group remove -y "Container Management"
    ## currently there is no docker-ce binary shipped for OL9_aarch64
    ## but Centos Stream 9 is the upstream of EL9 and OL9
    ## S9 docker-ce seems to be working just fine on OL9.
    ## We will, however, keep the docker-ce repo disabled by default just to
    ## be sure sure that a system update does not break the installation.
    ##
    ## In order to check if docker or any of it components have updates
    ## run `sudo dnf check-update --enablerepo=docker-ce-stable`
    ## and in order to update it/those
    ## `sudo dnf update --enablerepo=docker-ce-stable --nobest`
    sudo dnf config-manager --add-repo \
        https://download.docker.com/linux/centos/docker-ce.repo &&
        sudo rpm --import https://download.docker.com/linux/centos/gpg &&
        sudo dnf config-manager --set-disabled docker-ce-stable &&
        sudo dnf install --enablerepo=docker-ce-stable -y --nobest --allowerasing \
            docker-ce docker-ce-cli containerd.io docker-compose-plugin

    ## Enable and start docker service
    sudo systemctl enable --now docker

    ## Add user `$USER` to `docker` group
    if ! groups | grep -q docker; then
        sudo usermod -a -G docker "$USER"
    fi

    ## Allow ssh password authentication from docker subnets
    ## 1) add folowing block at the end of `/etc/ssh/sshd`
    ##    or in a new file at `/etc/ssh/sshd_config.d/`
    ## ```
    ## Match address 172.16.0.0/12
    ##    PasswordAuthentication yes
    ## ```
    ## TODO: Other SSH settings
    ## 2) Reload ssh server config
    #sudo systemctl reload sshd

    ## Install MOTD
    sudo cp ./etc/motd.d/98docker /etc/motd.d/

}

function jupyter() {
    sudo mkdir -p "$LAB_PATH"/{notebooks,datasets}
    sudo rsync -av --exclude ".git*" ./jupyter-docker/ "$LAB_PATH"
    test -f "$LAB_PATH/.env" && sudo rm -f "$LAB_PATH/.env.example" ||
        sudo cp "$LAB_PATH/.env.example" "$LAB_PATH/.env" &&
        echo "Don't foget to update \"$LAB_PATH/.env\" file"
    sudo chmod 600 "$LAB_PATH/.env"
    sudo chown -R "$USER": "$LAB_PATH"
    # Update JupyterLab path
    grep "$LAB_PATH" "$LAB_PATH/.env" || sed -i "s|/opt/jupyterlab|$LAB_PATH|" "$LAB_PATH/.env"
    # TODO: Make other .env variables configurable with this script

    sudo chown -R 1000:1000 "$LAB_PATH"/{notebooks,datasets}

    # Add $LAB_PATH to environment
    sudo cp ./etc/profile.d/jupyterlab.sh /etc/profile.d/jupyterlab.sh
    sudo chmod 644 /etc/profile.d/jupyterlab.sh
    sudo sed -i "s|###LAB_PATH###|$LAB_PATH|" /etc/profile.d/jupyterlab.sh

    # Install MOTD
    sudo cp ./etc/motd.d/99jupyterlab /etc/motd.d/
}

function build() {
    # Stage uses sudo, because without sudo docker-compose will fail on first run
    # I have't found a way to update the user's group membership without logging out
    # `newgrp docker` breaks the script
    function generate_token() {
        sudo "docker" compose -f "$LAB_PATH/docker-compose.yml" run \
            --rm datascience-notebook generate_token.py -p "$1" | grep ACCESS_TOKEN
    }
    # Build docker image
    sudo "docker" compose -f "$LAB_PATH/docker-compose.yml" build --pull
    # Spin down the container if it's running
    sudo "docker" compose -f "$LAB_PATH/docker-compose.yml" down || true

    # Update JupyterLab password
    if [[ "$JUPYTERLAB_PASSWORD" != "<empty>" ]]; then
        sed -i "s|ACCESS_TOKEN=.*|$(generate_token "$JUPYTERLAB_PASSWORD")|" "$LAB_PATH"/.env
    else
        CURRENT_TOKEN=$(grep ACCESS_TOKEN "$LAB_PATH"/.env)
        ORIG_TOKEN=$(grep ACCESS_TOKEN ./jupyter-docker/.env.example)
        if [[ "$CURRENT_TOKEN" == "$ORIG_TOKEN" ]]; then
            while [[ "$JUPYTERLAB_PASSWORD" == "<empty>" || "$JUPYTERLAB_PASSWORD" == "" ||
                ! ${#JUPYTERLAB_PASSWORD} -ge 8 ]]; do
                echo "JupyterLab password wasn't specified or is too short."
                echo
                echo "  NOTE: Password will not be echoed to the screen while typing."
                echo "  NOTE: Please don't use the same password as for the system user."
                echo "  NOTE: Password must be at least 8 characters long."
                echo
                echo "Enter the password now:"
                read -rs JUPYTERLAB_PASSWORD
            done
            sed -i "s|ACCESS_TOKEN=.*|$(generate_token "$JUPYTERLAB_PASSWORD")|" "$LAB_PATH"/.env
        fi
    fi

    # Re-deploy JupyterLab
    sudo "docker" compose -f "$LAB_PATH/docker-compose.yml" up -d &&
        sudo "docker" system prune -a -f && source "$LAB_PATH/.env" &&
        echo "JupyterLab is running at $BIND_HOST:$PORT"
}

function web() {
    # Nginx
    ## Install
    ### Generate temporary self-signed certificate
    test -L "/etc/ssl/private" || sudo ln -s /etc/pki/tls/private /etc/ssl/
    {
        test -f "/etc/ssl/private/default.key" &&
            test -f "/etc/ssl/certs/default.pem"
    } ||
        sudo openssl req -new -newkey rsa:2048 -days 3650 -nodes -x509 \
            -subj "/C=LV/ST=Riga/L=Riga/O=$(hostname)/CN=$(hostname)" \
            -keyout /etc/ssl/private/default.key \
            -out /etc/ssl/certs/default.pem
    test -f "/etc/ssl/private/dhparam.pem" ||
        sudo openssl dhparam -dsaparam -out /etc/ssl/private/dhparam.pem 4096
    ### Install Nginx package
    sudo dnf install -y nginx nginx-all-modules
    ### Configure Nginx
    ### Download and install custom error pages
    ### https://github.com/denysvitali/nginx-error-pages
    ERR_URL="https://github.com/denysvitali/nginx-error-pages/archive/refs/heads/master.zip"
    ERR_PATH="nginx-error-pages-master"
    ERR_TARGET_PATH="/usr/share/nginx/html/nginx-error-pages"
    test -d "$ERR_TARGET_PATH" || {
        wget $ERR_URL -O $ERR_PATH.zip &&
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
            sudo ln -s $ERR_TARGET_PATH/_errors/main.css $ERR_TARGET_PATH
    }
    ### Install custom nginx configuration
    test -d "$DEFAULTD" || sudo mkdir -p "$DEFAULTD"
    test -d "$CONFD" || sudo mkdir -p "$CONFD"
    {
        test -f "$NGINX/nginx.conf" &&
            cmp -s ./nginx/nginx.conf "$NGINX/nginx.conf"
    } ||
        sudo cp ./nginx/nginx.conf "$NGINX/nginx.conf"
    {
        test -f "$DEFAULTD/error-pages.conf" &&
            cmp -s ./nginx/error-pages.conf "$DEFAULTD/error-pages.conf"
    } ||
        sudo cp ./nginx/error-pages.conf "$DEFAULTD/error-pages.conf"
    {
        test -f "$DEFAULTD/ssl.conf" &&
            cmp -s ./nginx/ssl.conf "$DEFAULTD/ssl.conf"
    } ||
        sudo cp ./nginx/ssl.conf "$DEFAULTD/ssl.conf"
    {
        test -f "$CONFD/jupyterlab.conf" &&
            cmp -s ./nginx/jupyterlab.conf "$CONFD/jupyterlab.conf"
    } ||
        sudo cp ./nginx/jupyterlab.conf "$CONFD/jupyterlab.conf"

    ### Replace template values
    source "$LAB_PATH/.env"
    sudo sed -i "s|###BIND_HOST###|$BIND_HOST|g;s|###BIND_PORT###|$PORT|g;\
    s|###DOMAIN###|$DOMAIN|g" "$CONFD/jupyterlab.conf"

    ## Firewalld
    {
        sudo firewall-cmd --permanent --zone=public --add-service=http &&
            sudo firewall-cmd --permanent --zone=public --add-service=https &&
            sudo firewall-cmd --reload
    } || true

    ## SELinux
    sudo setsebool -P httpd_can_network_relay 1 || true
    sudo setsebool -P httpd_can_network_connect 1 || true

    ## Temporary disable $CONFD/jupyterlab.conf when first run
    test -f "/etc/ssl/cert/$DOMAIN.combined.pem" ||
        sudo mv "$CONFD/jupyterlab.conf" "$CONFD/jupyterlab.conf.disabled"

    ## Systemd
    sudo nginx -t &&
        sudo systemctl enable --now nginx
}

function dns() {
    # DNS
    # TODO: Implement automatic DNS configuration
    echo "ATENTION: Automatic DNS configuration is not implemented yet!"
    dig +short "$DOMAIN" @1.1.1.1 | grep -q "$IP" || {
        echo "DNS is not configured yet. Please configure it manually."
        echo "Set follwoing records:"
        echo "  \`$DOMAIN        3600   IN  A       $IP\`"
        echo "  \`www.$DOMAIN    3600   IN  CNAME   $DOMAIN\`"
        echo "See README.md for help."
        read -rp "Press enter once DNS is configured"
        dig +short "$DOMAIN" @1.1.1.1 | grep -q "$IP" || {
            echo "Could not resolve $DOMAIN to $IP"
            echo "Please check DNS configuration and try again."
            sleep 5
            dns
        }
    }
}

function ingress() {
    # Security List (FireWall)
    # TODO: Implement automatic security list configuration
    if [[ $(curl -sSI http://"$IP") &&
    $(curl -sSIk https://"$IP") ]]; then
        echo "WARNING:"
        echo "  This check might produce false positives."
        echo "  Double check the Security List ingress rules for port 80 and 443."
        echo
        echo "Inbound ports 80 and 443 seem to be open. Continuing execution."
        echo "Press Ctrl+C to abort."
        sleep 10
    else
        echo "Inbound ports 80 and 443 seem to be closed."
        echo "Please configure Security List ingress rules manually."
        echo "See README.md for help."
        read -rp "Press enter once ingress is configured"
        if [[ $(curl -sSI http://"$IP") &&
        $(curl -sSIk https://"$IP") ]]; then
            echo "Ingress is configured"
        else
            echo "Could not connect to $IP:80 and $IP:443"
            echo "This stage might produce false positives."
            echo "Presuming false positive and continuing execution."
            echo "Press Ctrl+C to abort."
            sleep 10
        fi
    fi
}

function cert() {
    # Install acme.sh if not installed already
    ACME_BASE_DIR="/etc/acme"
    ACME_BIN_DIR="/opt/bin/acme"
    ACME_CERT_DIR="$ACME_BASE_DIR/certs"
    ACME_CONF_DIR="$ACME_BASE_DIR/conf"
    sudo mkdir -p $ACME_BIN_DIR $ACME_CERT_DIR $ACME_CONF_DIR
    sudo chmod 750 $ACME_BASE_DIR
    sudo chown -R root:root $ACME_BASE_DIR
    test -f "$ACME_BIN_DIR/acme.sh" || {
        ACME_VERSION=$(curl -IsS https://github.com/acmesh-official/acme.sh/releases/latest |
            grep location: | sed "s/^.*\/\(.*\)\r$/\1/g") &&
            wget -O acme.tar.gz \
                "https://github.com/acmesh-official/acme.sh/archive/refs/tags/$ACME_VERSION.tar.gz" &&
            tar -xzf acme.tar.gz && cd "./acme.sh-$ACME_VERSION" && sudo ./acme.sh --force --install --home "$ACME_BIN_DIR" \
            --config-home "$ACME_BASE_DIR" --cert-home "$ACME_CERT_DIR" --accountemail "$EMAIL" \
            --accountkey "$ACME_CONF_DIR/myaccount.key" --accountconf "$ACME_CONF_DIR/myaccount.conf" && cd ..
    }

    # Issue certificate if not issued already
    sudo test -d "$ACME_CERT_DIR/$DOMAIN" || {
        sudo "$ACME_BIN_DIR/acme.sh" --home "$ACME_BIN_DIR" --config-home "$ACME_BASE_DIR" \
            --force --issue -d "$DOMAIN" -d www."$DOMAIN" -w /usr/share/nginx/html \
            --key-file "/etc/ssl/private/$DOMAIN.key" --cert-file "/etc/ssl/certs/$DOMAIN.crt" \
            --ca-file "/etc/ssl/certs/$DOMAIN.cacrt" --fullchain-file "/etc/ssl/certs/$DOMAIN.combined.pem" \
            --reloadcmd "systemctl reload nginx"
    }

    # Enable jupyterlab.conf
    test -f "$CONFD/jupyterlab.conf.disabled" &&
        sudo mv "$CONFD/jupyterlab.conf.disabled" "$CONFD/jupyterlab.conf" &&
        sudo nginx -t && sudo systemctl reload nginx

}

function cleanup() {
    rm -fr ./nginx-error-pages-master* ./acme*
}

# MAIN

## Argument parsing
### Install docopts if not already installed.
### http://docopt.org/
DOCOPTS_LIB="https://raw.githubusercontent.com/docopt/docopts/master/docopts.sh"
DOCOPTS_BIN="https://github.com/docopt/docopts/releases/latest/download/docopts_linux_arm"

test -f docopts.sh || wget "$DOCOPTS_LIB"
test -x docopts || (wget -O docopts "$DOCOPTS_BIN" && chmod +x docopts)
### Initialize docopts.
PATH=.:$PATH
source docopts.sh

help=$(docopt_get_help_string "$0")

### Parse arguments.
parsed=$(docopts -A myargs -h "$help" -V $version : "$@")
eval "$parsed"

set -u

if [[ ${myargs["-l"]} == 1 ]]; then
    echo "Available stages: ${!ALL_STAGES[*]}"
    exit 0
fi

## Main logic
for a in "${!myargs[@]}"; do
    #echo "$a = ${myargs[$a]}"
    ### Set variables from arguments
    # TODO: Make sure that arguments are really required when stage filter is applied
    #### Define JupyterLab domain ($DOMAIN)
    if [[ "$a" == "--domain" ]]; then
        if [[ "${myargs[$a]}" == "" ]]; then
            echo "Domain name is required."
            exit 1
        elif [[ "${myargs[$a]}" == "\$DOMAIN" ]]; then
            if [[ "${DOMAIN-}" == "" ]]; then
                echo "Domain is required."
                exit 1
            fi
        elif [[ "${myargs[$a]}" =~ ^[a-zA-Z0-9.-]+$ ]]; then
            DOMAIN="${myargs[$a]}"
        else
            echo "Invalid domain name provided: ${myargs[$a]}"
            exit 1
        fi
        echo "Domain: $DOMAIN"
    #### Define acme.sh account email ($EMAIL)
    elif [[ "$a" == "--email" ]]; then
        if [[ "${myargs[$a]}" == "\$EMAIL" ]]; then
            if [[ "${EMAIL-}" == "" ]]; then
                echo "Email address is required."
                exit 1
            fi
        elif [[ ${myargs[$a]} =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+(\.[A-Za-z]+)*$ ]]; then
            EMAIL="${myargs[$a]}"
        else
            echo "Invalid email address."
        fi
        echo "Email: $EMAIL"
    #### Define system user ($USER)
    elif [[ "$a" == "--system-user" ]]; then
        if [[ "${myargs[$a]}" == "" || "${myargs[$a]}" == "opc" ]]; then
            USER=opc
        elif [[ ${myargs[$a]} =~ ^[a-z_]([a-z0-9_-]{0,31}|[a-z0-9_-]{0,30}\$)$ ]]; then
            USER=${myargs[$a]}
        else
            echo "Invalid username \"${myargs[$a]}\" provided"
            exit 1
        fi
        echo "System user: $USER"
    #### Define system user's password ($USER_PASSWORD)
    elif [[ "$a" == "--system-user-password" ]]; then
        if [[ ${myargs[$a]} == "" ]]; then
            USER_PASSWORD="<empty>"
        else
            USER_PASSWORD="${myargs[$a]}"
        fi
    ### Define JupyterLab password ($JUPYTERLAB_PASSWORD)
    elif [[ $a == "--jupyterlab-password" ]]; then
        if [[ ${myargs[$a]} == "" ]]; then
            JUPYTERLAB_PASSWORD="<empty>"
        else
            JUPYTERLAB_PASSWORD="${myargs[$a]}"
        fi
    ### Define JupyterLab system path ($LAB_PATH)
    elif [[ $a == "--lab-path" ]]; then
        if [[ ${myargs[$a]} == "" ]]; then
            LAB_PATH="/opt/jupyterlab"
        elif [[ "${myargs[$a]}" == "\$LAB_PATH" ]]; then
            if [[ "${LAB_PATH-}" == "" ]]; then
                echo "LAB_PATH is required."
                exit 1
            fi
        elif [[ ${myargs[$a]} =~ ^(/)?([^/\0]+(/)?)+$ ]]; then
            LAB_PATH="${myargs[$a]}"
        else
            echo "Invalid app path provided: ${myargs[$a]}"
            exit 1
        fi
        echo "App path: $LAB_PATH"
    ### Parse stages
    elif [[ $a == "--stages" ]]; then
        if [[ -z ${myargs[$a]} ]]; then
            STAGES=("${!ALL_STAGES[@]}")
        else
            if echo -n "${myargs[$a]}" |
                grep -qP '^(all(,|$))?(-(?!all)[a-z]+,?)*$'; then
                splitStages
                for stage in "${STAGES[@]}"; do
                    EXCLUDE+=("${stage[@]:1}")
                done
                STAGES=($(comm -3 <(printf "%s\n" "${!ALL_STAGES[@]}" |
                    sort) <(printf "%s\n" "${EXCLUDE[@]}" | sort) | sort -n))
            elif echo -n "${myargs[$a]}" |
                grep -qP '^(-all(,|$))?((?!all)[a-z]+,?)*$'; then
                splitStages
            else
                echo "Invalid stage argument: ${myargs[$a]}"
                exit 1
            fi
        fi

        for stage in "${STAGES[@]}"; do
            if [[ ! "${!ALL_STAGES[*]}" =~ ${stage} ]]; then
                echo "Invalid stage: $stage"
                exit 1
            else
                STAGE_INDEXES+=("${ALL_STAGES[$stage]}")
            fi
        done

    fi
done

STAGE_INDEXES=($(printf "%s\n" "${STAGE_INDEXES[@]}" | sort -n))

### Run stages
for i in "${STAGE_INDEXES[@]}"; do
    for stage in "${!ALL_STAGES[@]}"; do
        if [[ ${ALL_STAGES[$stage]} == "$i" ]]; then
            echo "Performing stage: $stage"
            sleep 3
            $stage
        fi
    done
done

sleep 7

if [[ $(curl -sSI https://"$DOMAIN") ]]; then
    echo "Your JupyterLab instance is ready at https://$DOMAIN"
else
    echo "Something went wrong. Please check the logs."
fi
