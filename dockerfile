FROM perl:5.32.1-buster

ARG NMIS_HOME=/usr/local/nmis9
# ARG NMIS_UID=1100
# ARG NMIS_GID=1100
ARG NMIS_USER=nmis
ARG NMIS_GROUP=nmis

RUN \
  apt-get update  > /dev/null && \
  apt-get install --assume-yes \
    ca-certificates \
    curl > /dev/null

RUN \
  apt-get -y install tini libcairo2 libcairo2-dev libglib2.0-dev libpango1.0-dev libxml2 libxml2-dev \
  libgd-gd2-perl libnet-ssleay-perl libcrypt-ssleay-perl fping nmap snmp snmpd snmptrapd \
  libnet-snmp-perl libcrypt-passwdmd5-perl libjson-xs-perl libnet-dns-perl libio-socket-ssl-perl \
  libwww-perl libnet-smtp-ssl-perl libnet-smtps-perl libcrypt-unixcrypt-perl libcrypt-rijndael-perl \
  libuuid-tiny-perl libproc-processtable-perl libdigest-sha-perl libnet-snpp-perl libdbi-perl \
  libtime-parsedate-perl libsoap-lite-perl libauthen-simple-radius-perl libauthen-tacacsplus-perl libauthen-sasl-perl \
  rrdtool librrds-perl libsys-syslog-perl libtest-deep-perl libcrypt-des-perl libdigest-hmac-perl libclone-perl libexcel-writer-xlsx-perl libio-pipely-perl \
  libdatetime-perl libdatetime-set-perl libcgi-pm-perl libmojolicious-perl libstatistics-lite-perl libtime-moment-perl libscalar-list-utils-perl liblist-moreutils-perl \
  libdatetime-timezone-perl libterm-readkey-perl libcarp-assert-perl libcgi-session-perl libtext-csv-perl libnet-ldap-perl libtie-ixhash-perl libmojolicious-plugin-cgi-perl libmongodb-perl;


WORKDIR ${NMIS_HOME}

COPY . ${NMIS_HOME}

EXPOSE 8080

RUN mkdir ${NMIS_HOME}/conf
RUN mkdir ${NMIS_HOME}/database
RUN mkdir ${NMIS_HOME}/var
RUN mkdir ${NMIS_HOME}/logs

VOLUME ${NMIS_HOME}/conf
VOLUME ${NMIS_HOME}/database
VOLUME ${NMIS_HOME}/var
VOLUME ${NMIS_HOME}/logs


ENTRYPOINT ["tini", "--", "/usr/local/nmis9/docker-entrypoint.sh"]

LABEL maintainer="James Greewnwood. <james.greenwood@firstwave.com>" 
