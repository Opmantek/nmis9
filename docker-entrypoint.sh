#!/bin/bash

set -e

# shellcheck disable=SC1091
source /etc/profile

setup() {
  # Create data directories
  for d in assets var/nmis_system models-custem database conf logs
  do
    dir=${NMIS_HOME}/${d}
    [[ -d "${dir}" ]] || mkdir -p "${dir}"

    if [[ "$(stat --format='%U:%G' "$dir")" != 'nmis:nmis' ]] && [[ -w "$dir" ]]; then
      chown -R nmis:nmis "$dir" || echo "Warning can not change owner to nmis:nmis"
    fi
  done

  #boostrap config items
  for f in users.dat Config.nmis
  do
    file="${NMIS_HOME}"/conf/"${f}"
    [[ -f "${file}" ]] || cp "${NMIS_HOME}"/conf-default/"${f}" "${NMIS_HOME}"/conf/"${f}"
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

}


nmis_frontend() {
    set -m
      /usr/local/nmis9/bin/nmisd foreground=1 debug=1 &
      /usr/local/nmis9/script/nmisx daemon -m production -p -l "http://*:8080"
    fg %1
}


run() {
  setup
  nmis_frontend

}

run "$@"