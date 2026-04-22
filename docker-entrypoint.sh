#!/bin/bash

set -e

NMIS_HOME=/usr/local/nmis9
NMIS_LOG=${NMIS_HOME}/logs/nmis.log
NMIS_USER=nmis
NMIS_GROUP=nmis

# shellcheck disable=SC1091
source /etc/profile

setup() {
  # Create data directories
  for d in assets var/nmis_system models-custom database conf logs htdocs/cache htdocs/nmis9
  do
    dir=${NMIS_HOME}/${d}

    if [[ "$(stat --format='%U:%G' "$dir")" != 'nmis:nmis' ]] && [[ -w "$dir" ]]; then
      chown -R nmis:nmis "$dir" || echo "Warning can not change owner to nmis:nmis"
    fi
  done

  # fake a couple of aseets dirs for mojo
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
  rm -f "${NMIS_HOME}/var/nmis_system/nmisd.pid"
}

nmis_frontend() {
  su -s /bin/bash ${NMIS_USER} -c '
    /usr/local/nmis9/bin/nmisd foreground=1 &
    /usr/local/nmis9/script/nmisx daemon -m production -p -l "http://*:8080" &
  '
}

setup_db() {
  yes '' | /usr/local/nmis9/admin/setup_mongodb.pl
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
  nmis_frontend

  # Tail NMIS out to keep container alive
  sleep 5
  tail -f "${NMIS_LOG}"
}

run "$@"
