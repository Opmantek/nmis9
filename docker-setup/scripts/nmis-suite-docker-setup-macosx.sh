#!/usr/bin/env bash
# This script is used to install the NMIS Suite for Docker onto a MacOS based machine.
# It installs Docker, Docker Compose and their dependencies,directories and configuration files for the NMIS Suite for Docker.
# It starts the NMIS Suite for Docker and tells you how to access it.
# For more information see https://docs.community.firstwave.com/wiki/x/AQCs5g

set -o errexit
set -o pipefail

mkdir -p ~/nmis-suite
cd ~/nmis-suite

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

# Test and print Docker and Docker Compose versions
echo -e "\n$(docker version)\n"
echo -e "\n$(docker compose version)\n"

# Pull NMIS/OMK Docker related configurations
DOCKER_CONF_URL=https://raw.githubusercontent.com/Opmantek/nmis9/feature_docker_9_5_2/conf-default/docker_conf.zip
curl -LO $DOCKER_CONF_URL >/dev/null 2>&1
unzip -n docker_conf.zip
cp -a docker/. .
sleep 7
echo -e "\n\n"
docker compose down >/dev/null 
echo -e "\n\n"

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

  echo -e \
  "\nPlease record these randomly generated passwords for Mongo and Redis:
     
     MONGO USERNAME: $DOCKER_MONGO_USER
     MONGO PASSWORD: $DOCKER_MONGO_PWD
     REDIS PASSWORD: $DOCKER_REDIS_PWD
   
They are used by the NMIS/OMK container to connect to the Mongo and Redis instance,
and are stored in the .env file located in $DOCKER_NMIS_HOME. Please backup this file.\n\n"
fi

# Compose up NMIS/OMK services and check status
echo -e "\nSpinning up containers..."
docker compose up -d >/dev/null 2>&1
sleep 7
echo -e "\n$(docker ps)\n\n"

echo -e \
"\nThe NMIS Suite dashboard should be accesible at:

    http://<HOSTNAME_OR_IP>:8070/omk

If your browser is running on the same machine as NMIS Suite, this would be:

    http://localhost:8070/omk\n"