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

# Update policies
for policy in policies/*.hcl; do
  vault policy write $(basename -s .hcl $policy) ${policy}
done

OIDC_AUTH_ACCESSOR=$(vault read -field accessor sys/auth/oidc)

entities=(
  knudtson.erik@gmail.com
)

for entity in ${entities[@]}; do
    echo "Syncing entity ${entity}"
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
