#!/usr/bin/env bash
# This script performs general setup of Docker on Debian

set -o errexit
set -o pipefail

# Update repositories and install a few required packages
sudo apt-get update > /dev/null
sudo apt-get install ca-certificates curl zip wget -y > /dev/null

# Add Docker's official GPG key:
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc

# Add the docker repository to apt sources:
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian \
  $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

# Update apt repositories to pick up new docker repository and install docker related packages
sudo apt-get update  > /dev/null
sudo apt-get install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin docker-compose -y  > /dev/null

# Start the docker service
echo -e "\nStarting Docker..."
service docker start

# Create Docker user and add to the Docker group
DOCKER_USER="docker-nmis"
if [[ ! $(id -u $DOCKER_USER) ]]; then
  DOCKER_PWD="$(openssl rand -base64 12)"
  sudo useradd -m -s /bin/bash $DOCKER_USER
  sudo usermod -aG docker $DOCKER_USER
  echo "$DOCKER_USER:$DOCKER_PWD" | sudo chpasswd
  echo -e "\nSave these credentials for your Docker user: \
          \nUSER: $DOCKER_USER \
          \nPASSWORD: $DOCKER_PWD\n"
fi

# Test and print Docker and Docker Compose versions
echo -e "\n$(docker version)\n"
echo -e "\n$(docker compose version)\n"

# Create directories related to NMIS/OMK Docker
DOCKER_NMIS_HOME=/home/$DOCKER_USER/nmis-suite
cd $DOCKER_NMIS_HOME

# Get NMIS/OMK configuration files
DOCKER_CONF_URL=https://raw.githubusercontent.com/Opmantek/nmis9/feature_docker_9_5_2/conf-default/docker/docker_conf.zip
curl -LO $DOCKER_CONF_URL > /dev/null
unzip -n docker_conf.zip
cp -a docker_conf/. .
sleep 7
docker compose down > /dev/null

chown -R $DOCKER_USER:docker $DOCKER_NMIS_HOME

# Update NMIS & OMK configuration on script first time run
FLAG_FILE=.init_nmis
if [[ ! -f $FLAG_FILE ]]; then
  DOCKER_MONGO_USER=mongo
  DOCKER_MONGO_PWD="$(openssl rand -base64 12)"
  DOCKER_REDIS_PWD="$(openssl rand -base64 12)"

  sed -i "s|^MONGODB_USERNAME=.*|MONGODB_USERNAME=$DOCKER_MONGO_USER|" .env
  sed -i "s|^MONGODB_PASSWORD=.*|MONGODB_PASSWORD=$DOCKER_MONGO_PWD|" .env
  sed -i "s|^REDIS_PASSWORD=.*|REDIS_PASSWORD=$DOCKER_REDIS_PWD|" .env

  sed -i "s|'db_username.*'|'db_username' => '$DOCKER_MONGO_USER'|" Config.nmis
  sed -i "s|'db_password.*'|'db_password' => '$DOCKER_MONGO_PWD'|" Config.nmis
  sed -i "s|\"db_username\".*|"'"db_username"'": \"$DOCKER_MONGO_USER\",|" opCommon.json
  sed -i "s|\"db_password\".*|"'"db_password"'": \"$DOCKER_MONGO_PWD\",|" opCommon.json
  sed -i "s|\"redis_password\".*|"'"redis_password"'": \"$DOCKER_REDIS_PWD\",|" opCommon.json
  echo "" > $FLAG_FILE
fi

# Compose up NMIS/OMK services and check status
echo -e "\nSpinning up containers..."
docker compose up -d > /dev/null
sleep 7
echo -e "\n$(docker ps)\n"