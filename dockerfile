#remove everything OMK from this file  if you want just nmis
#copy a pre-built OMK artifact to root directory of this build if you want OMK
FROM perl:5.32.1-slim-threaded-bullseye

LABEL maintainer="James Greewnwood. <james.greenwood@firstwave.com>" 
LABEL maintainer="Louis Tissington. <louis.tissington@firstwave.com>"
LABEL maintainer="Kishen Kumar. <kishen.kumar@firstwave.com>"

ARG NMIS_HOME=/usr/local/nmis9
ARG NMIS_USER=nmis
ARG NMIS_GROUP=nmis
ARG NMIS_USER_UID=10001
ARG NMIS_USER_GID=10001

ENV PERL5LIB="/usr/share/perl5:/usr/lib/x86_64-linux-gnu/perl5/5.32"

RUN apt-get update  > /dev/null && \
    apt-get install --assume-yes \
      gnupg \
      git \
      ca-certificates \
      curl > /dev/null

RUN curl -fsSL https://www.mongodb.org/static/pgp/server-6.0.asc | gpg --dearmor -o /usr/share/keyrings/mongodb-server-6.0.gpg && \
    echo "deb [ signed-by=/usr/share/keyrings/mongodb-server-6.0.gpg ] http://repo.mongodb.org/apt/debian bullseye/mongodb-org/6.0 main" | tee /etc/apt/sources.list.d/mongodb-org-6.0.list

RUN apt-get update  > /dev/null && \
    apt-get -y install --no-install-recommends tini \
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
    libconfig-yaml-perl \
    sysstat \
    net-tools \
    mongodb-mongosh \
    libfile-slurp-perl \
    iproute2 \
    procps \
    libyaml-libyaml-perl \
    #OMK related packages from here down
    sshpass \
    unixodbc \
    odbcinst \
    tdsodbc \
    logrotate && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/* 

WORKDIR /tmp

# Soft link because some tools look for /usr/bin/ip not /sbin/ip
RUN ln -s /sbin/ip /usr/bin/ip

# Systemctl redirect when scripts try call systemctl inside the container
RUN git clone https://github.com/gdraheim/docker-systemctl-replacement && \
    cp docker-systemctl-replacement/files/docker/systemctl3.py /usr/bin/systemctl && \
    rm -rf docker-systemctl-replacement

RUN addgroup --gid ${NMIS_USER_GID} ${NMIS_GROUP} && \
    useradd --uid ${NMIS_USER_UID} --gid ${NMIS_GROUP} --shell /bin/bash ${NMIS_USER}

WORKDIR ${NMIS_HOME}

COPY . ${NMIS_HOME}

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
    mv /usr/local/omk/install/opeventsd.init.d.bak /etc/init.d/opeventsd && \
    rm /etc/apt/sources.list.d/mongodb-org-6.0.list

# NMIS Web 8080
# OMK Web 8042
# MTA Port 25
# SNMP Ports 161/udp 162/udp
# NetFlow Port 2055
EXPOSE 8080 \
       8042 \
       25 \
       161/udp \
       162/udp \
       2055/udp

ENTRYPOINT ["tini", "--", "/usr/local/nmis9/docker-entrypoint.sh"]
