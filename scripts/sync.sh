#!/bin/bash

for DIR in ./policies; do
  if [ ! -d "$DIR" ]; then
    echo "Required directory $DIR does not exist, exiting. Run script from the root directory."
    exit 1
  fi
done

if [ "$(git branch --show-current)" != "main" ]; then
  echo "Unable to sync on non-main branch"
  exit 1
fi

# Update user/entity policies
for policy in policies/users/*.hcl; do
  vault policy write $(basename -s .hcl $policy) ${policy}
done

# Enable the OIDC auth backend (will error out if already configured)
set +e
vault auth enable -listing-visibility="unauth" oidc > /dev/null 2>&1
set -e

OIDC_AUTH_ACCESSOR=$(vault read -field accessor sys/auth/oidc)

entities=(
  knudtson.erik@gmail.com
)

for entity in ${entities[@]}; do
    echo "Syncing user entity into Vault: ${entity}"

    # Sync Vault canonical entities, set everyone to use admin policy for now
    vault write -format=json identity/entity name="${entity}" policies="${entity}"

    ENTITY_ID=$(vault read -field=id identity/entity/name/${entity})

    # Sync entitiy aliases that map OIDC email claims to the corresponding Vault
    # canonical entity.
    vault write identity/entity-alias name="${entity}" \
         mount_accessor="$OIDC_AUTH_ACCESSOR" \
         canonical_id="$ENTITY_ID" \
         >/dev/null 2>&1
done

# Setup Kubernetes cluster auth
for cluster in policies/kubernetes/*; do
    cluster=$(basename $cluster)
    # Iterate over every namespace in cluster
    for namespace in policies/kubernetes/"${cluster}"/*; do
        namespace=$(basename $namespace)
        # Iterate over service accounts in namespace
        for serviceaccountpolicy in policies/kubernetes/"${cluster}"/"${namespace}"/*; do
            serviceaccount=$(basename -s .hcl $serviceaccountpolicy)
            vault policy write kubernetes-${cluster}-${namespace}-${serviceaccount} ${serviceaccountpolicy}
        done
    done
done

# Provision K8s cluster auth, if it's not enabled for a cluster already
# This uses the client SA's JWT as the TokenReviewer - i.e. a client passes its SA JWT to Vault
# and Vault hands that token to the K8s APIserver for validation.  Once the apiserver validates the token,
# Vault can rely on the claims in the JWT and grant secret access based on the policy assigned to the SA.
for cluster in policies/kubernetes/*; do
    cluster=$(basename $cluster)
    path="kubernetes-${cluster}"

    if ! (vault auth list | grep -q "${path}/"); then
        vault auth enable \
            -path="${path}" \
            -description="Kubernetes auth for ${cluster} cluster" \
            kubernetes > /dev/null 2>&1

        vault write auth/kubernetes-${cluster}/config \
            kubernetes_host="@kubernetes/${cluster}/apiserver_address" \
            kubernetes_ca_cert="@kubernetes/${cluster}/ca.crt" \
            disable_local_ca_jwt=true

        echo "Kubernetes auth enabled for the ${cluster} cluster"
    fi
done

# Setup Kubernetes auth roles for service accounts
# This will assign Vault policies to K8s serviceaccounts used to authenticate with Vault.
# These roles are assigned policies whose names are a combination of the cluster + namespace + serviceaccount.
# All Kubernetes service accounts used for auth here must have a ClusteRoleBinding to the system:auth-delegator ClusterRole in order to work correctly.
for cluster in policies/kubernetes/*; do
    cluster=$(basename $cluster)
    for namespace in policies/kubernetes/"${cluster}"/*; do
        namespace=$(basename $namespace)
        for serviceaccountpolicy in policies/kubernetes/"${cluster}"/"${namespace}"/*; do
            serviceaccount=$(basename -s .hcl $serviceaccountpolicy)
            echo "Provisioning k8s auth role for cluster: ${cluster} namespace: ${namespace} serviceaccount: ${serviceaccount}"
            vault write "auth/kubernetes-${cluster}/role/${namespace}-${serviceaccount}" \
                bound_service_account_names="${serviceaccount}" \
                bound_service_account_namespaces="${namespace}" \
                policies="kubernetes-${cluster}-${namespace}-${serviceaccount}" \
                ttl=1h
        done
    done
done
