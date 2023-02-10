FROM debian:stretch

EXPOSE 8080

RUN \
  apt-get -qq update && \
  apt-get -qq dist-upgrade -y;

RUN \
  apt-get -qq -y install gcc git-core build-essential libffi-dev libssl-dev \
  libcurl4-openssl-dev libreadline-dev autoconf automake make perl;

RUN \
  cpan App::cpanminus;

RUN \
  apt-get -y install  libcairo2 libcairo2-dev libglib2.0-dev libpango1.0-dev libxml2 libxml2-dev \
  libgd-gd2-perl libnet-ssleay-perl libcrypt-ssleay-perl fping nmap snmp snmpd snmptrapd \
  libnet-snmp-perl libcrypt-passwdmd5-perl libjson-xs-perl libnet-dns-perl libio-socket-ssl-perl \
  libwww-perl libnet-smtp-ssl-perl libnet-smtps-perl libcrypt-unixcrypt-perl libcrypt-rijndael-perl \
  libuuid-tiny-perl libproc-processtable-perl libdigest-sha-perl libnet-ldap-perl libnet-snpp-perl libdbi-perl \
  libtime-modules-perl libsoap-lite-perl libauthen-simple-radius-perl libauthen-tacacsplus-perl libauthen-sasl-perl \
  rrdtool librrds-perl libsys-syslog-perl libtest-deep-perl libcrypt-des-perl libdigest-hmac-perl libclone-perl libexcel-writer-xlsx-perl libio-pipely-perl \
  libdatetime-perl libdatetime-set-perl libcgi-pm-perl;


RUN \
  cpanm Term::ReadKey List::Util Mojolicious Mojolicious::Plugin::CGI Time::Moment DateTime::TimeZone List::MoreUtils Carp::Assert Statistics::Lite CGI::Session Text::CSV;

RUN \
  cpanm --notest MongoDB@2.2.0;


WORKDIR /usr/local/nmis9

COPY . ./

RUN mkdir -p var/nmis_system
RUN mkdir -p models-custom
RUN mkdir -p database
RUN mkdir -p conf

RUN mkdir -p assets

RUN ln -s menu assets/menu9
RUN ln -s htdocs/cache htdocs/nmis9/cache


COPY ./conf-default/users.dat ./conf/
COPY ./conf-default/Config.nmis ./conf/


# CMD ["/usr/local/nmis9/script/nmisx", "daemon", "-l", "http://*:8080"]