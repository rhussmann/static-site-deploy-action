#!/usr/bin/env bash

set -e

KONG_URL=$KONG_HOST:$KONG_PORT

cleanup() {
    rm -rf $GITHUB_WORKSPACE/tmp/.ssh
    wg-quick down wg0
}

trap cleanup EXIT

cp $GITHUB_WORKSPACE/site.conf.template /tmp/$SHORT_NAME.conf
sed -i -e "s@{{DOMAIN_NAME}}@$DOMAIN_NAME@" /tmp/$SHORT_NAME.conf
sed -i -e "s@{{SHORT_NAME}}@$SHORT_NAME@" /tmp/$SHORT_NAME.conf

cp $GITHUB_WORKSPACE/tunnel.conf /tmp/

sed -i -e "s@{{CTX_WIREGUARD_PRIVATE_KEY}}@$CTX_WIREGUARD_PRIVATE_KEY@" /tmp/tunnel.conf
sed -i -e "s@{{CTX_WIREGUARD_SERVER_PUBLIC_KEY}}@$CTX_WIREGUARD_SERVER_PUBLIC_KEY@" /tmp/tunnel.conf
sed -i -e "s@{{CTX_WIREGUARD_SERVER_ENDPOINT}}@$CTX_WIREGUARD_SERVER_ENDPOINT@" /tmp/tunnel.conf

sudo apt install wireguard
sudo cp /tmp/tunnel.conf /etc/wireguard/wg0.conf

wg-quick up wg0

mkdir -p $GITHUB_WORKSPACE/tmp/.ssh
echo "$CTX_SERVER_DEPLOY_SECRET" >> $GITHUB_WORKSPACE/tmp/.ssh/id_rsa
chmod 600 $GITHUB_WORKSPACE/tmp/.ssh/id_rsa

scp -i $GITHUB_WORKSPACE/tmp/.ssh/id_rsa -o StrictHostKeyChecking=no /tmp/$SHORT_NAME.conf $SSH_USER@$DOCKER_HOST:~/nginx-data/configs/

ssh -i $GITHUB_WORKSPACE/tmp/.ssh/id_rsa -o StrictHostKeyChecking=no $SSH_USER@$DOCKER_HOST mkdir -p ./nginx-data/sites/$SHORT_NAME
scp -i $GITHUB_WORKSPACE/tmp/.ssh/id_rsa -o StrictHostKeyChecking=no -r $DEPLOY_ASSETS $SSH_USER@$DOCKER_HOST:./nginx-data/sites/$SHORT_NAME/

ssh -i $GITHUB_WORKSPACE/tmp/.ssh/id_rsa -o StrictHostKeyChecking=no $SSH_USER@$DOCKER_HOST 'cd ~/Code/kong && /usr/local/bin/docker compose kill -s HUP nginx'

ROUTE_EXISTS=$(curl -fs $KONG_URL/services/$NGINX_SERVICE_NAME/routes | jq ".data | map(select(.hosts[0] == \"$DOMAIN_NAME\")) | length")

# Add a route to the new domain if it doesn't exist
if [ "$ROUTE_EXISTS" == "0" ]; then
    echo "Adding route for $DOMAIN_NAME to Kong..."
    curl -fs -X POST $KONG_URL/services/$NGINX_SERVICE_NAME/routes \
	 -d "hosts[]=$DOMAIN_NAME" \
	 -d 'preserve_host=true' | jq -C '.'
else
    echo "Route to $DOMAIN_NAME already exists in $NGINX_SERVICE_NAME routes"
fi

# Check to see if this domain exists in the acme plugin
ACME_PLUGIN_ID=$(curl -fs $KONG_URL/plugins | jq -jr '.data | map(select(.name == "acme"))[].id')
EXISTING_DOMAINS=$(curl -fs $KONG_URL/plugins/$ACME_PLUGIN_ID | jq -r '.config.domains[]')

DOMAIN_FOUND="false"
while IFS= read -r line; do
    if [ "$line" == "$DOMAIN_NAME" ]; then
	DOMAIN_FOUND="true"
    fi
done <<< "$EXISTING_DOMAINS"

if [ "$DOMAIN_FOUND" == "false" ]; then
    echo "Domain $DOMAIN_NAME not found, adding to ACME plugin..."

    DOMAIN_LIST=""

    while IFS= read -r line; do
	DOMAIN_LIST+="-d config.domains[]=$line "
    done <<< "$EXISTING_DOMAINS"
    DOMAIN_LIST+="-d config.domains[]=$DOMAIN_NAME"

    curl -fs -XPATCH $KONG_URL/plugins/$ACME_PLUGIN_ID $DOMAIN_LIST

    echo "Requesting certificate for $DOMAIN_NAME"
    curl -fs $KONG_URL/acme -d host=$DOMAIN_NAME
else
    echo "$DOMAIN_NAME already in list of ACME domains"
fi

ROUTE_ID=$(curl -fs $KONG_URL/services/$NGINX_SERVICE_NAME/routes | jq -jr ".data | map(select(.hosts[0] == \"$DOMAIN_NAME\"))[].id")
REDIRECT_EXISTS=$(curl -fs $KONG_URL/routes/$ROUTE_ID/plugins | jq -j '.data | map(select(.name == "pre-function")) | length')

if [ "$REDIRECT_EXISTS" == "0" ]; then
    echo "Adding http->https redirect"
    curl -fs -X POST $KONG_URL/routes/$ROUTE_ID/plugins \
	 -F "name=pre-function" \
	 -F "config.header_filter[1]=@custom.lua"
else
    echo "HTTP -> HTTPS redirect already exists for $DOMAIN_NAME"
fi
