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
    #
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
