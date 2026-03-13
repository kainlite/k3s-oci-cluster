#!/bin/bash

wait_lb() {
while [ true ]
do
  curl --output /dev/null --silent -k https://${k3s_url}:6443
  if [[ "$?" -eq 0 ]]; then
    break
  fi
  sleep 5
  echo "wait for LB"
done
}

render_staging_issuer(){
STAGING_ISSUER_RESOURCE=$1
cat << 'EOF' > $STAGING_ISSUER_RESOURCE
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
 name: letsencrypt-staging
 namespace: cert-manager
spec:
 acme:
   # The ACME server URL
   server: https://acme-staging-v02.api.letsencrypt.org/directory
   # Email address used for ACME registration
   email: ${certmanager_email_address}
   # Name of a secret used to store the ACME account private key
   privateKeySecretRef:
     name: letsencrypt-staging
   # Enable the HTTP-01 challenge provider
   solvers:
   - http01:
       ingress:
         class: traefik
EOF
}

render_prod_issuer(){
PROD_ISSUER_RESOURCE=$1
cat << 'EOF' > $PROD_ISSUER_RESOURCE
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
  namespace: cert-manager
spec:
  acme:
    # The ACME server URL
    server: https://acme-v02.api.letsencrypt.org/directory
    # Email address used for ACME registration
    email: ${certmanager_email_address}
    # Name of a secret used to store the ACME account private key
    privateKeySecretRef:
      name: letsencrypt-prod
    # Enable the HTTP-01 challenge provider
    solvers:
    - http01:
        ingress:
          class: traefik
EOF
}

render_traefik_config(){
cat << 'EOF' > $TRAEFIK_CONFIG_FILE
apiVersion: helm.cattle.io/v1
kind: HelmChartConfig
metadata:
  name: traefik
  namespace: kube-system
spec:
  valuesContent: |-
    ports:
      web:
        nodePort: ${ingress_controller_http_nodeport}
      websecure:
        nodePort: ${ingress_controller_https_nodeport}
    service:
      type: NodePort
    additionalArguments:
      - "--entryPoints.web.proxyProtocol.trustedIPs=10.0.0.0/24"
      - "--entryPoints.websecure.proxyProtocol.trustedIPs=10.0.0.0/24"
      - "--entryPoints.web.forwardedHeaders.insecure=true"
      - "--entryPoints.websecure.forwardedHeaders.insecure=true"
EOF
}

# Disable firewall
/usr/sbin/netfilter-persistent stop
/usr/sbin/netfilter-persistent flush

systemctl stop netfilter-persistent.service
systemctl disable netfilter-persistent.service
# END Disable firewall

apt-get update
apt-get install -y software-properties-common jq
DEBIAN_FRONTEND=noninteractive apt-get upgrade -y
DEBIAN_FRONTEND=noninteractive apt-get install --no-install-recommends -y  python3 python3-pip
pip install oci-cli

local_ip=$(curl -s -H "Authorization: Bearer Oracle" -L http://169.254.169.254/opc/v2/vnics/ | jq -r '.[0].privateIp')
flannel_iface=$(ip -4 route ls | grep default | grep -Po '(?<=dev )(\S+)')

export OCI_CLI_AUTH=instance_principal
first_instance=$(oci compute instance list --compartment-id ${compartment_ocid} --availability-domain ${availability_domain} --lifecycle-state RUNNING --sort-by TIMECREATED  | jq -r '.data[]|select(."display-name" | endswith("k3s-servers")) | .["display-name"]' | tail -n 1)
instance_id=$(curl -s -H "Authorization: Bearer Oracle" -L http://169.254.169.254/opc/v2/instance | jq -r '.displayName')
first_last="last"

%{ if !install_traefik }
disable_traefik="--disable traefik"
%{ endif }

%{ if expose_kubeapi }
tls_extra_san="--tls-san ${k3s_tls_san_public}"
%{ endif }

if [[ "$first_instance" == "$instance_id" ]]; then
  echo "I'm the first yeeee: Cluster init!"
  first_last="first"
  until (curl -sfL https://get.k3s.io | K3S_TOKEN=${k3s_token} sh -s - --cluster-init $disable_traefik --node-ip $local_ip --advertise-address $local_ip --flannel-iface $flannel_iface --tls-san ${k3s_tls_san} $tls_extra_san); do
    echo 'k3s did not install correctly'
    sleep 2
  done
else
  echo ":( Cluster join"
  wait_lb
  until (curl -sfL https://get.k3s.io | K3S_TOKEN=${k3s_token} sh -s - --server https://${k3s_url}:6443 $disable_traefik --node-ip $local_ip --advertise-address $local_ip --flannel-iface $flannel_iface --tls-san ${k3s_tls_san} $tls_extra_san); do
    echo 'k3s did not install correctly'
    sleep 2
  done
fi

%{ if is_k3s_server }
until kubectl get pods -A | grep 'Running'; do
  echo 'Waiting for k3s startup'
  sleep 5
done

%{ if install_longhorn }
if [[ "$first_last" == "first" ]]; then
  DEBIAN_FRONTEND=noninteractive apt-get install --no-install-recommends -y  open-iscsi curl util-linux
  systemctl enable iscsid.service
  systemctl start iscsid.service
  kubectl apply -f https://raw.githubusercontent.com/longhorn/longhorn/${longhorn_release}/deploy/longhorn.yaml
  kubectl create -f https://raw.githubusercontent.com/longhorn/longhorn/${longhorn_release}/examples/storageclass.yaml
fi
%{ endif }

%{ if install_traefik }
if [[ "$first_last" == "first" ]]; then
  TRAEFIK_CONFIG_FILE=/root/traefik-config.yaml
  render_traefik_config
  kubectl apply -f $TRAEFIK_CONFIG_FILE
fi
%{ endif }

%{ if install_certmanager }
if [[ "$first_last" == "first" ]]; then
  kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/${certmanager_release}/cert-manager.yaml
  render_staging_issuer /root/staging_issuer.yaml
  render_prod_issuer /root/prod_issuer.yaml

  # Wait cert-manager to be ready
  until kubectl get pods -n cert-manager | grep 'Running'; do
    echo 'Waiting for cert-manager to be ready'
    sleep 15
  done

  kubectl create -f /root/prod_issuer.yaml
  kubectl create -f /root/staging_issuer.yaml
fi
%{ endif }

%{ if install_argocd }
if [[ "$first_last" == "first" ]]; then
  kubectl create namespace argocd
  kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/${argocd_release}/manifests/install.yaml

%{ if install_argocd_image_updater }
  kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj-labs/argocd-image-updater/${argocd_image_updater_release}/manifests/install.yaml
%{ endif }
fi
%{ endif }

%{ endif }
