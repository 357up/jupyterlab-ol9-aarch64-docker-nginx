#!/usr/bin/env bash
#
# Usage:
#   ./skeleton.sh ( [--stage=all] | --stage=[all,]<-stage>... | --stage=[-all,]<stage>... ) [options]
#   ./skeleton.sh -h | --help
#   ./skeleton.sh -l | --list-stages
#   ./skeleton.sh --version
#
# Options:
#   -u,--system-user=<user>             Application user [default: opc]
#   --system-user-password=<pw>         Application user password [default: <empty>]
#   -d,--domain=<domain>                Application domain [default: $DOMAIN]
#   -e,--email=<email>                  Email address to send acme.sh notifications to [default: $EMAIL]
#   -p,--lab-path=<path>                Path to lab directory [default: /opt/jupyter]
#
# Examples:
#   ./skeleton.sh --stage=-dns,-cert -p /opt/jupyter -u opc -e $EMAIL

#set -x
#set -e

# GLOBALS
version='0.0.3alpha'
declare -A ALL_STAGES=(
    ["prep"]=0
    ["docker"]=1
    ["build"]=2
    ["jupyter"]=3
    ["web"]=4
    ["ingress"]=5
    ["dns"]=6
    ["cert"]=7
    ["cleanup"]=8)

# HELPER FUNCTIONS

function splitStages() {
    INPUT=$(awk -F"," '{for(i=1;i<=NF;i++){printf "%s\n", $i}}' <<<"${myargs[$a]}")
    while read -r line; do
        if [[ $line =~ ^-?all$ ]]; then
            true
        else
            STAGES+=("$line")
        fi
    done <<<"$INPUT"
}

# STAGES

function prep() {
    # System packages
    ## install updates
    sudo dnf update -y

    ## remove some preinstalled garbage
    sudo dnf remove -y $(rpm -qa | grep cock)

    ## Install EPEL repo
    sudo dnf install -y oracle-epel-release-el9

    ## Enable optional repos
    sudo dnf config-manager --set-enabled \
        {ol9_addons,ol9_codeready_builder,ol9_developer,ol9_developer_EPEL}

    ## Install useful tools
    sudo dnf install -y vim git htop ncdu ansible-core \
        policycoreutils-python-utils netcat bind-utils \
        wget curl unzip jq
}

function docker() {
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
    ## TODO: Ask password at the beggining and
    sudo passwd -S opc | grep "Password locked" && sudo passwd opc

}

function jupyter() {
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
}

function build() {
    # Build docker image
    #LAB_PATH="/opt/jupyter"
    #docker build -t jupyterlab:latest $LAB_PATH
    echo "Build not implemented yet"
}

function web() {
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
        sudo openssl dhparam -out /etc/ssl/private/dhparam.pem 4096
    ### Install Nginx package
    sudo dnf install -y nginx nginx-all-modules
    ### Configure Nginx
    ### Download and install custom error pages
    ### https://github.com/denysvitali/nginx-error-pages
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
    ### Install custom nginx config
    NGINX="/etc/nginx"
    DEFAULTD="$NGINX/default.d"
    CONFD="$NGINX/conf.d"
    test -d "$DEFAULTD" || sudo mkdir -p "$DEFAULTD"
    test -d "$CONFD" || sudo mkdir -p "$CONFD"
    (test -f "$NGINX/nginx.conf" &&
        cmp -s ./nginx/nginx.conf "$NGINX/nginx.conf") ||
        sudo cp ./nginx/nginx.conf "$NGINX/nginx.conf"
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

    ## Firewalld
    (sudo firewall-cmd --permanent --zone=public --add-service=http &&
        sudo firewall-cmd --permanent --zone=public --add-service=https &&
        sudo firewall-cmd --reload) || true

    ## SELinux
    sudo setsebool -P httpd_can_network_relay 1 || true
    sudo setsebool -P httpd_can_network_connect 1 || true

    ## Systemd
    sudo nginx -t &&
        sudo systemctl enable --now nginx
}

function dns() {
    # DNS
    # TODO: Implement automatic DNS configuration
    echo "ATENTION: Automatic DNS configuration is not implemented yet!"
    dig +short $DOMAIN @1.1.1.1 | grep -q "$IP" || (
        echo "DNS is not configured yet. Please configure it manually."
        echo "Set follwoing records:"
        echo "  \`$DOMAIN        3600   IN  A       $IP\`"
        echo "  \`www.$DOMAIN    3600   IN  CNAME   $DOMAIN\`"
        echo "See README.md for help."
        read -p "Press enter once DNS is configured"
        dig +short $DOMAIN @1.1.1.1 | grep -q "$IP" || (
            clear
            echo "Could not resolve $DOMAIN to $IP"
            echo "Please check DNS configuration and try again."
            sleep 5
            dns
        )
    )
}

function ingress() {
    # Security List (FireWall)
    # TODO: Implement automatic security list configuration
    if [[ $(nc -z $IP 80) && $(nc -z $IP 443) ]]; then
        echo "WARNING:"
        echo "  This check might produce false positives."
        echo "  Double check the Security List ingress rules for port 80 and 443."
        echo
        echo "Inbound ports 80 and 443 seem to be open."
        read -p "Press enter to continue"
    else
        echo "Inbound ports 80 and 443 seem to be closed." 
        echo "Please configure Security List ingress rules manually."
        echo "See README.md for help."
        read -p "Press enter once ingress is configured"
        if [[ $(nc -z $IP 80) && $(nc -z $IP 443) ]]; then
            echo "Ingress is configured"
        else
            clear
            echo "Could not connect to $IP:80 and $IP:443"
            echo "This stage might produce false positives."
            echo "Presuming false positive and continuing execution."
            echo "Press Ctrl+C to abort."
            sleep 5
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
    test -f "$ACME_BIN_DIR/acme.sh" || (
        ACME_VERSION=$(curl -IsS https://github.com/acmesh-official/acme.sh/releases/latest |
            grep location: | sed "s/^.*\/\(.*\)\r$/\1/g") &&
            wget -O acme.tar.gz \
                https://github.com/acmesh-official/acme.sh/archive/refs/tags/$ACME_VERSION.tar.gz &&
            tar -xzf acme.tar.gz && acme.sh-$ACME_VERSION/acme.sh --install --home $ACME_BIN_DIR \
            --config-home $ACME_BASE_DIR --cert-home $ACME_CERT_DIR --accountemail $EMAIL \
            --accountkey $ACME_CONF_DIR/myaccount.key --accountconf $ACME_CONF_DIR/myaccount.conf
    )
    # Issue certificate if not issued already
    test -d "$ACME_CERT_DIR/$DOMAIN" || (
        $ACME_BIN_DIR/acme.sh --home $ACME_BIN_DIR --config-home $ACME_BASE_DIR \
            --issue -d $DOMAIN -d www.$DOMAIN --dns -w /usr/share/nginx/html \
            --key-file /etc/ssl/private/$DOMAIN.key --cert-file /etc/ssl/certs/$DOMAIN.crt \
            --ca-file /etc/ssl/certs/$DOMAIN.cacrt --fullchain-file /etc/ssl/certs/$DOMAIN.combined.pem \
            --reloadcmd "systemctl reload nginx"
    )

}

function cleanup() {
    rm -fr ./nginx-error-pages-master* ./acme*
}

# MAIN

## Argument parsing
### Install docopts if not already installed.
### http://docopt.org/
DOCOPTS_LIB="https://raw.githubusercontent.com/docopt/docopts/master/docopts.sh"
DOCOPTS_BIN="https://github.com/docopt/docopts/releases/latest/download/docopts_linux_amd64"

test -f docopts.sh || wget $DOCOPTS_LIB
test -x docopts || (wget -O docopts $DOCOPTS_BIN && chmod +x docopts)
### Initialize docopts.
PATH=.:$PATH
source docopts.sh

help=$(docopt_get_help_string $0)

### Parse arguments.
parsed=$(docopts -A myargs -h "$help" -V $version : "$@")
eval "$parsed"

set -u

### Parse stages.
for a in ${!myargs[@]}; do
    echo "$a = ${myargs[$a]}"
    if [[ $a == "-l" && ${myargs[$a]} == 1 ]]; then
        echo "Available stages: ${!ALL_STAGES[@]}"
        exit 0
    elif [[ $a == "--stage" ]]; then
        if [[ -z ${myargs[$a]} ]]; then
            STAGES=("${!ALL_STAGES[@]}")
        else
            if [[ $(echo -n "${myargs[$a]}" |
                grep -P '^(all(,|$))?(-(?!all)[a-z]+,?)*$') ]]; then
                splitStages
                for stage in ${STAGES[@]}; do
                    EXCLUDE+=("${stage[@]:1}")
                done
                STAGES=($(comm -3 <(printf "%s\n" "${!ALL_STAGES[@]}" |
                    sort) <(printf "%s\n" "${EXCLUDE[@]}" | sort) | sort -n))
            elif [[ $(echo -n "${myargs[$a]}" |
                grep -P '^(-all(,|$))?((?!all)[a-z]+,?)*$') ]]; then
                splitStages
            else
                echo "Invalid stage argument: ${myargs[$a]}"
                exit 1
            fi
            if [[ ${STAGES[@]} != ${!ALL_STAGES[@]} ]]; then
                for stage in ${STAGES[@]}; do
                    if [[ ! " ${!ALL_STAGES[@]} " =~ " ${stage} " ]]; then
                        echo "Invalid stage: $stage"
                        exit 1
                    else
                        STAGE_INDEXES+=("${ALL_STAGES[$stage]}")
                        STAGE_INDEXES=($(printf "%s\n" "${STAGE_INDEXES[@]}" | sort -n))
                    fi
                done
            fi
        fi

        for i in ${STAGE_INDEXES[@]}; do
            for stage in ${!ALL_STAGES[@]}; do
                if [[ ${ALL_STAGES[$stage]} == $i ]]; then
                    printf "Performing stage: %s\n" "$stage"
                    # Run stage function
                    $stage
                fi
            done
        done
    fi
done
