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
  for d in assets var/nmis_system models-custom database conf logs
  do
    dir=${NMIS_HOME}/${d}
    [[ -d "${dir}" ]] || mkdir -p "${dir}"
    
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
  rm -f /usr/local/nmis9/var/nmis_system/nmisd.pid
}


nmis_frontend() {
  set -m
    /usr/local/nmis9/bin/nmisd foreground=1 debug=1 &
    /usr/bin/morbo /usr/local/nmis9/script/nmisx daemon -m production -p -l "http://*:8080" &
}


setup_db() {
  yes '' | /usr/local/nmis9/admin/setup_mongodb.pl
}


run() {
  setup
  setup_db
  nmis_frontend

  # Tail something to keep the container alive
  tail -f /dev/null
}

run "$@"