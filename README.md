# jupyterlab-ol9-aarch64-docker-nginx <p>(great name, I know 😎)</p>

  Semi-automatically deploys JupyterLab to Oracle Cloud's VM.Standard.A1.Flex VM running Oracle Linux 9 (aarch64) using [docker-ce](https://www.docker.com/products/container-runtime/) as the container runtime, [Nginx](https://www.nginx.com/) as a reverse proxy, and awesome [acme.sh](https://github.com/acmesh-official/acme.sh) for TLS.

## Installation

Clone this repo

```bash
mkdir /tmp/install
git clone https://github.com/357up/jupyterlab-ol9-aarch64-docker-nginx /tmp/install
cd /tmp/install
```

## Usage

```bash
Usage:
  ./setup.sh ( [--stages=all] | --stages=[all,]<-stage>... | --stages=[-all,]<stage>... ) [options]
  ./setup.sh -h | --help
  ./setup.sh -l | --list-stages
  ./setup.sh --version

Options:
  -u,--system-user=<user>             Application user [default: opc]
  --system-user-password=<pw>         Application user password [default: <empty>]
  --jupyterlab-password=<pw>          JupyterLab password [default: <empty>]
  -d,--domain=<domain>                Application domain [default: $DOMAIN]
  -e,--email=<email>                  Email address to send acme.sh notifications to [default: $EMAIL]
  -p,--lab-path=<path>                Path to lab directory [default: /opt/jupyter]

Examples:
  ./setup.sh --stages=-dns,-cert -p /opt/jupyter -u opc -e $EMAIL
  ./setup.sh --stages=-all,lab -p /opt/jupyter --jupyterlab-password=TOP-SECRET
```
At the minimum `-e`|`--email=<email>` options (or `$EMAIL` environment variable) and `-d`|`--domain=<domain>` (or `$DOMAIN` environment variable) are required. Email is used for acme.sh account registration.
Script tries to follow DevOps desired state principle, so you should be able to re-run the script (or any of the stages) however times you want and it should result in the same state - running, accessible JupyterLab instance. However, more thorough testing is required in order for me to recommend running it without real need.

### DNS

Currently, the setup script does not support automatic DNS configuration. At the `dns` stage it will pause and wait until the user hits ENTER. Here is how you configure DNS records in CloudFlare, presuming that `$DOMAIN` is `lab.ve.id.lv`:

 1. Log in to [CloudFlare](https://dash.cloudflare.com/login/)
 2. Search and select our domain <p>![](https://lh3.googleusercontent.com/gixTOrrhe9604s00IXlMoXESJWF7XoJgDujOx0PdK4m2gUQ-qkQZbkHoVTZ34y0rtPw=w2400) </p>
3. From the left-hand menu, select DNS <p>![](https://lh6.googleusercontent.com/-b-AwVWHHNReKltwIbhl9f3YXW5eU_NhdAz8vQW4w43DxJs9bJSceqvTngsHXDPUbIY=w2400) </p>
4. Add a new A record <p>![](https://lh5.googleusercontent.com/m252JIBA6g0ZbdRAQPu7htN84G5_j4LB5NiBxdPZRA35aXxu-fgJeToiLs9X695y7F0=w2400) </p><p>![](https://lh4.googleusercontent.com/vfTM2ik9kXotdoy_8N7rMm9Oa-_s_Bh0yYg4bpRarSG-8AZ9f7UF4oJoNRYyL7EFoP8=w2400)</p>
5. Add a new CNAME record <p>![](https://lh3.googleusercontent.com/4whULWychlmzbLN5qZeZsI__nEDkomwpNoDnuK7DOqUTAx51Nnmrmx3ULw58rWmpg_U=w2400)</p><p>![](https://lh3.googleusercontent.com/xdPLxKnse7SQXBI781MfZWK_rSTYVoFqbsoF8drdZ8EwSRST4nQXpQKZfNB2TVNBbfw=w2400)</p>
6. Et voilà! <p>![](https://lh6.googleusercontent.com/H8QbYGz88iVubrBHiVlBS5sDe3Gt7DIqsENTpStZh7QcGq9PUut4I0JrN_6tltsVw2I=w2400)</p>

### Oracle Cloud Virtual Firewall (Security List)
Currently, the setup script does not support automatic OCI virtual firewall configuration. In the `ingress` stage it pauses untill user presses ENTER. Here is how you configure the OCI firewall:

 1. Log in to the [OCI panel](https://cloud.oracle.com/)
 2. From the main navigation menu, select **Networking**→**Virtual Cloud Networks**<p>![](https://lh5.googleusercontent.com/TmYHOTVeQ8RNdWar1sXOq3S3lOWMcplEgRTqlbaJKp9bBqcYaFe_a6FiqYEKxjQtRJ8=w2400)</p>
 3. From the list of Virtual Cloud Networks, select the one you used for JupyterLab VM <p>![](https://lh5.googleusercontent.com/kFzrt_7rRd1A1p7fSwyeeKHbg-Hu8_m7vR-YDLKyEqX5C5oi8-vroYHpvz2A7V5aORA=w2400)</p>
 4. From the left-hand menu select **Security Lists**. Then select the security list used for public traffic. <p>![](https://lh6.googleusercontent.com/IuAfzc6DsRCCPNxm3qiUERGMksmPSxLR_c4ENj4Bk60FdXoO-KYSzXfciuaduo5LSBk=w2400)</p>
 5. Make sure you are in the **Ingress** table. Press **Add Ingress Rules** button<p>![](https://lh6.googleusercontent.com/fQUlEWK-MPVP-iQbqDq2zMe5UhWFMQGcJnDnLwRs3aaLoGzVSMXQrGSV5LBcF4TNSbo=w2400)</p>
 6. We are going to add two rules. We are going to add two rules. The first one is with source CIDR `0.0.0.0/0` and **TCP** port **80** as the destination. The second one is with source CIDR `0.0.0.0/0` and **TCP** port **443** as the destination. <p>![](https://lh6.googleusercontent.com/nepcdmMxtz0_TeZjXU8fX-Id0CNSry0c5Axd4zuCBrItgFu3rd_p2AzY3ZR6O-4bONg=w2400)</p>
 7. You should now see 2 extra rules in the ingress table. <p>![](https://lh4.googleusercontent.com/r5MwlrZqj3t4wL7Qwa5Hn2yWFAbnWyapKDCR4pbnewbjIKpiH4devA965RK3YYVkSUs=w2400)</p>

## TO-DO

 - [ ] Automatic Cloudflare DNS configuration 
 - [ ] Automatic Configuration of Oracle Cloud's virtual firewall
 - [ ] Improve documentation (MOTD, READMEs)
 - [ ] Make this an Ansible role

## Contributing

If you find a bug, feel free to open an issue. All pull requests are welcome and will be reviewed.

## License

[MIT](LICENSE.md)