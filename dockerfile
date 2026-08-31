FROM debian:bookworm-slim

LABEL maintainer="James Greewnwood. <james.greenwood@firstwave.com>" 
LABEL maintainer="Louis Tissington. <louis.tissington@firstwave.com>"
LABEL maintainer="Kishen Kumar. <kishen.kumar@firstwave.com>"

ARG NMIS_HOME=/usr/local/nmis9
ARG NMIS_USER=nmis
ARG NMIS_GROUP=nmis
ARG NMIS_USER_UID=10001
ARG NMIS_USER_GID=10001

ENV PERL5LIB=/usr/local/lib/site_perl/lib/perl5:/usr/local/lib/site_perl/lib/perl5/x86_64-linux-gnu:/usr/share/perl5:/usr/lib/x86_64-linux-gnu/perl5/5.32
ENV CONTAINER=1

RUN apt-get update  > /dev/null && \
    apt-get install --assume-yes \
      gnupg \
      git \
      ca-certificates \
      curl > /dev/null

RUN curl -fsSL https://www.mongodb.org/static/pgp/server-7.0.asc | gpg --dearmor -o /usr/share/keyrings/mongodb-server-7.0.gpg && \
    echo "deb [ signed-by=/usr/share/keyrings/mongodb-server-7.0.gpg ] http://repo.mongodb.org/apt/debian bullseye/mongodb-org/7.0 main" | tee /etc/apt/sources.list.d/mongodb-org-7.0.list

RUN apt-get update  > /dev/null && \
    apt-get -y install --no-install-recommends \
    tini \
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
    gcc \
    make \
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
    # OMK-12695: encryption of secrets is on by default; nmisd's isEOSAvailable
    # startup gate requires these crypto modules or it refuses to start
    libcrypt-cbc-perl \
    libcryptx-perl \
    libmath-random-secure-perl \
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
    sshpass \
    unixodbc \
    odbcinst \
    tdsodbc && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/* 

# Essential cpanm perl modules
RUN cpanm --notest --no-interactive \
    --local-lib=/usr/local/lib/site_perl \
    IO::Socket::IP \
    Socket \
    ExtUtils::Constant \
    JSON::PP \
    Time::Local \
    Test::More \
    Config::AutoConf \
    Path::Tiny \
    DateTime::Locale \
    Mojolicious@9.39 \
    Devel::Size@0.84 \
    # Non-essential cpanm perl modules
    Net::SFTP::Foreign \
    Net::LDAP \
    Net::LDAPS \
    IO::Socket::SSL \
    Crypt::UnixCrypt \
    Authen::TacacsPlus \
    Authen::Simple::RADIUS \
    SOAP::Lite

WORKDIR /tmp

# Soft link because some tools look for /usr/bin/ip not /sbin/ip
# Systemctl redirect when scripts try call systemctl inside the container
RUN git clone https://github.com/gdraheim/docker-systemctl-replacement && \
    cp docker-systemctl-replacement/files/docker/systemctl3.py /usr/bin/systemctl && \
    rm -rf docker-systemctl-replacement

RUN addgroup --gid ${NMIS_USER_GID} ${NMIS_GROUP} && \
    useradd --uid ${NMIS_USER_UID} --gid ${NMIS_GROUP} --shell /bin/bash ${NMIS_USER}

WORKDIR ${NMIS_HOME}

COPY . ${NMIS_HOME}

RUN mkdir -p ${NMIS_HOME}/conf \
    ${NMIS_HOME}/conf/conf.d \
    ${NMIS_HOME}/database \
    ${NMIS_HOME}/var \
    ${NMIS_HOME}/logs \
    ${NMIS_HOME}/htdocs/nmis9 \
    ${NMIS_HOME}/htdocs/cache \
    ${NMIS_HOME}/assets \
    ${NMIS_HOME}/models-custom

COPY ../conf-default/Users.nmis \
     ../conf-default/users.dat \
     ../conf-default/Access.nmis \
     ${NMIS_HOME}/conf/

COPY ../conf-default/docker/Config.nmis.docker ${NMIS_HOME}/conf/Config.nmis
COPY ../conf-default/snmpd/snmpd.conf ../conf-default/snmpd/snmptrapd.conf  /etc/snmp/

VOLUME ${NMIS_HOME}/conf \
       ${NMIS_HOME}/database \
       ${NMIS_HOME}/var \
       ${NMIS_HOME}/logs \
       ${NMIS_HOME}/models-custom

RUN rm /etc/apt/sources.list.d/mongodb-org-7.0.list

# NMIS user ownership
RUN chown -R ${NMIS_USER}:${NMIS_GROUP} ${NMIS_HOME}

# NMIS Web 8080
# OMK Web 8042
# MTA Port 25
# SNMP Ports 161/udp
# NetFlow Port 2055
EXPOSE 8080 \
       8042 \
       25 \
       161/udp \
       2055/udp

ENTRYPOINT ["tini", "--", "/usr/local/nmis9/docker-entrypoint.sh"]
