#remove everything OMK from this file  if you want just nmis
#copy a pre-built OMK artifact to root directory of this build if you want OMK
FROM perl:5.32.1-slim-threaded-bullseye

LABEL maintainer="James Greewnwood. <james.greenwood@firstwave.com>" 
LABEL maintainer="Louis Tissington. <louis.tissington@firstwave.com>"
LABEL maintainer="Kishen Kumar. <kishen.kumar@firstwave.com>"

ARG NMIS_HOME=/usr/local/nmis9
ARG NMIS_USER=nmis
ARG NMIS_GROUP=nmis

ENV PERL5LIB="/usr/share/perl5:/usr/lib/x86_64-linux-gnu/perl5/5.32"

RUN apt-get update  > /dev/null && \
    apt-get install --assume-yes \
      ca-certificates \
      curl > /dev/null

RUN apt-get -y install --no-install-recommends tini \
    libcairo2 \
    libcairo2-dev \
    libglib2.0-dev \
    libpango1.0-dev \
    libxml2 libxml2-dev \
    libgd-gd2-perl \ 
    libnet-ssleay-perl \
    libcrypt-ssleay-perl \
    fping \
    nmap \
    snmp \
    snmpd \ 
    snmptrapd \
    iputils-ping \
    dnsutils \
    mtr \
    traceroute \
    libnet-snmp-perl \
    libcrypt-passwdmd5-perl \
    libjson-xs-perl \
    libnet-dns-perl \
    libio-socket-ssl-perl \
    libwww-perl \
    libnet-smtp-ssl-perl \
    libnet-smtps-perl \
    libcrypt-unixcrypt-perl \
    libcrypt-rijndael-perl \
    libuuid-tiny-perl \
    libproc-processtable-perl \
    libdigest-sha-perl \
    libnet-snpp-perl \
    libdbi-perl \
    libtime-parsedate-perl \
    libsoap-lite-perl \
    libauthen-simple-radius-perl \
    libauthen-tacacsplus-perl \
    libauthen-sasl-perl \
    rrdtool \
    librrds-perl \
    libsys-syslog-perl \
    libtest-deep-perl \
    libcrypt-des-perl \
    libdigest-hmac-perl \
    libclone-perl \
    libexcel-writer-xlsx-perl \
    libio-pipely-perl \
    libdatetime-perl \
    libdatetime-set-perl \
    libcgi-pm-perl \
    libmojolicious-perl \
    libstatistics-lite-perl \
    libtime-moment-perl \
    libscalar-list-utils-perl \
    liblist-moreutils-perl \
    cpanminus \
    libdatetime-timezone-perl \
    libterm-readkey-perl \
    libcarp-assert-perl \
    libcgi-session-perl \
    libtext-csv-perl \
    libnet-ldap-perl \
    libtie-ixhash-perl \
    libmojolicious-plugin-cgi-perl \
    libmongodb-perl \
    #OMK related packages from here down
    sshpass \
    unixodbc \
    odbcinst \
    tdsodbc \
    logrotate && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/* 

WORKDIR ${NMIS_HOME}

COPY . ${NMIS_HOME}

EXPOSE 8080

RUN mkdir ${NMIS_HOME}/conf \
    ${NMIS_HOME}/database \
    ${NMIS_HOME}/var \
    ${NMIS_HOME}/logs \
    ${NMIS_HOME}/htdocs/nmis9 \
    ${NMIS_HOME}/assets

COPY ./conf-default/Users.nmis ${NMIS_HOME}/conf
COPY ./conf-default/users.dat ${NMIS_HOME}/conf
COPY ./conf-default/Access.nmis ${NMIS_HOME}/conf
COPY ./conf-default/Config.nmis ${NMIS_HOME}/conf

VOLUME ${NMIS_HOME}/conf
VOLUME ${NMIS_HOME}/database
VOLUME ${NMIS_HOME}/var
VOLUME ${NMIS_HOME}/logs

RUN mv /usr/local/nmis9/omk /usr/local/ && \
    mv /usr/local/omk/install/omkd.init.d.bak /etc/init.d/omkd && \
    mv /usr/local/omk/install/opchartsd.init.d.bak /etc/init.d/opchartsd && \
    mv /usr/local/omk/install/opconfigd.init.d.bak /etc/init.d/opconfigd && \
    mv /usr/local/omk/install/opeventsd.init.d.bak /etc/init.d/opeventsd

EXPOSE 8042

ENTRYPOINT ["tini", "--", "/usr/local/nmis9/docker-entrypoint.sh"]