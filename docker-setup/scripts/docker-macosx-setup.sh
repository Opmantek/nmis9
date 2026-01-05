#!/usr/bin/env bash
# This script is for local docker development and not for production use

set -o errexit
set -o pipefail

mkdir -p ~/nmis_docker
cd ~/nmis_docker

# Check if Docker is installed
FIRST_SETUP=0
if [[ ! $(command -v docker) ]]; then
    ARCH=$(uname -m)
    if [[ "$ARCH" == "arm64" ]]; then
    URL="https://desktop.docker.com/mac/main/arm64/Docker.dmg"
    else
    URL="https://desktop.docker.com/mac/main/amd64/Docker.dmg"
    fi

    curl -L -o Docker.dmg $URL > /dev/null
    hdiutil attach Docker.dmg > /dev/null
    sudo /Volumes/Docker/Docker.app/Contents/MacOS/install --accept-license
    hdiutil detach -force /Volumes/Docker
    FIRST_SETUP=1
fi

# Start Docker service
open -a /Applications/Docker.app
if [[ $FIRST_SETUP == 1 ]]; then
    echo -e "\nOn first time setup you will need to allow priviledged access to Docker"
    echo "Enter your password into the Docker popup window to allow access"
    echo "Please type y|Y to continue once you have:"
    read INPUT
    while [[ "$INPUT" != ^[Yy]$ ]]; do
        echo "Please type y or Y to continue"
        read INPUT
    done
fi

# Pull NMIS/OMK Docker related configurations
DOCKER_CONF_URL=https://raw.githubusercontent.com/Opmantek/nmis9/feature_docker_9_5_2/conf-default/docker/docker_conf.zip
curl -LO $DOCKER_CONF_URL > /dev/null
unzip -n docker_conf.zip
cp -a docker_conf/. .
sleep 7
docker compose down > /dev/null

# Update NMIS & OMK configuration
FLAG_FILE=.init_nmis
if [[ ! -f $FLAG_FILE ]]; then
    DOCKER_MONGO_USER=mongo
    DOCKER_MONGO_PWD="$(openssl rand -base64 12)"
    DOCKER_REDIS_PWD="$(openssl rand -base64 12)"

    sed -i '' "s|^MONGODB_USERNAME=.*|MONGODB_USERNAME=$DOCKER_MONGO_USER|" .env
    sed -i '' "s|^MONGODB_PASSWORD=.*|MONGODB_PASSWORD=$DOCKER_MONGO_PWD|" .env
    sed -i '' "s|^REDIS_PASSWORD=.*|REDIS_PASSWORD=$DOCKER_REDIS_PWD|" .env

    sed -i '' "s|'db_username.*'|'db_username' => '$DOCKER_MONGO_USER'|" Config.nmis
    sed -i '' "s|'db_password.*'|'db_password' => '$DOCKER_MONGO_PWD'|" Config.nmis
    sed -i '' "s|\"db_username\".*|"'"db_username"'": \"$DOCKER_MONGO_USER\",|" opCommon.json
    sed -i '' "s|\"db_password\".*|"'"db_password"'": \"$DOCKER_MONGO_PWD\",|" opCommon.json
    sed -i '' "s|\"redis_password\".*|"'"redis_password"'": \"$DOCKER_REDIS_PWD\",|" opCommon.json
    echo "" > $FLAG_FILE
fi

# Compose up NMIS/OMK services and check status
echo -e "\nSpinning up containers..."
docker compose up -d > /dev/null
sleep 7
echo -e "\n$(docker ps)\n"