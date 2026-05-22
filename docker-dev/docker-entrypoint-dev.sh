#!/bin/bash

set -e

NMIS_HOME=/usr/local/nmis9
# Perl lib location seperate from Debian vendor and Debian site perl lib location
# Avoids conflicts between Debian perl and cpanm perl package installations
PERL5LIB=/usr/local/lib/site_perl/lib/perl5:/usr/local/lib/site_perl/lib/perl5/x86_64-linux-gnu

# shellcheck disable=SC1091
source /etc/profile

setup() {
  # Create data directories
  for d in assets var/nmis_system models-custom database conf logs htdocs/nmis9 htdocs/cache
  do
    dir=${NMIS_HOME}/${d}
    [[ -d "${dir}" ]] || mkdir -p "${dir}"    
  done

  # Add base configuration
  for f in Users.nmis users.dat Access.nmis; do
    if [[ ! -e "${NMIS_HOME}/conf/$f" ]]; then
      cp -a "${NMIS_HOME}/conf-default/$f" "${NMIS_HOME}/conf/$f"
    fi
  done

  if [[ ! -e "${NMIS_HOME}/conf/Config.nmis" ]]; then
    cp "${NMIS_HOME}/conf-default/docker/Config.nmis.docker" "${NMIS_HOME}/conf/Config.nmis"
  fi

  # fake a couple of assets dirs for mojo
  ln -s "${NMIS_HOME}"/menu "${NMIS_HOME}"/assets/menu9 || echo "Could not symlink menu9 dir"
  ln -s "${NMIS_HOME}"/htdocs/cache "${NMIS_HOME}"/htdocs/nmis9/cache || echo "Could not symlink cache dir"

  NODESIMPORT="${NMIS_HOME}"/import
  #check if there are any nodes to import
  echo "seeing if there are any nodes to import from ${NODESIMPORT}"
  if [ -d "${NODESIMPORT}" ]; then
    for filename in "$NODESIMPORT"/*.json; do
     echo "maybe a filename? $filename"
      if [ -e "$filename" ]; then
        echo "creating node from file: ${filename}"
        /usr/local/nmis9/admin/node_admin.pl act=import file="${filename}" || echo "could not create node"
      fi
    done
  fi

  # Remove pid file that gets saved in /var mount, otherwise stops nmisd from running when starting the container
  rm -f /usr/local/nmis9/var/nmis_system/nmisd.pid
}


nmis_frontend() {
  set -m
    /usr/local/nmis9/bin/nmisd foreground=1 debug=1 &
    /usr/bin/morbo /usr/local/nmis9/script/nmisx daemon -m development -p -l "http://*:8080" &
}


setup_db() {
  yes '' | /usr/local/nmis9/admin/setup_mongodb.pl
}

dev_user_map() {
  group="$(getent group "$DEV_GID" | cut -d: -f1)"
  user="$(getent passwd "$DEV_UID" | cut -d: -f1)"

  if [[ -n "$group" ]]; then
    DEV_GROUP="$group"
  else
    groupadd -g "$DEV_GID" dev
    DEV_GROUP="dev"
  fi

  if [[ -n "$user" ]]; then
    DEV_USER="$user"
  else
    useradd -m -u "$DEV_UID" -g "${DEV_GROUP}" -s /bin/bash dev
    DEV_USER="dev"
  fi

  find "$NMIS_HOME" \
    -path "$NMIS_HOME/.git" -prune -o \
    -exec chown "$DEV_UID:$DEV_GID" {} +
}

# Start any services required by NMIS
start_apps() {
  services=("snmpd" "snmptrapd")
  for service in "${services[@]}"; do
    echo "Starting $service daemon..."
    service $service start
    if [ $? -eq 0 ]; then
        echo "$service service started successfully."
    else
        echo "Failed to start $service service."
    fi
  done
}

run() {
  setup
  setup_db
  start_apps
  dev_user_map
  nmis_frontend
  # Tail something to keep the container alive
  tail -f /dev/null
}

run "$@"