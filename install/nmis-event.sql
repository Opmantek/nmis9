/*
SQLyog Community Edition- MySQL GUI v6.12 RC
MySQL - 5.0.51a-24 : Database - nmis
*********************************************************************
Eric 1 July 2009 added user create statements
First, you should have installed mysql-server and setup a root user.

Edit nmis/conf/my.cnf and tweak for your envrionment. The version here is for CentOS


Install mysql

shell> yum install mysql*
shell> cp my.cnf /etc/my.cnf
shell> service mysqld start
shell> chkconfig mysqld on
shell> mysqladmin -u root password '<password>'
shell> mysqladmin -u root -h '<your host.domainname>' password '<password>' -p
.. enter <password>
shell>

Then set up the nmis database and event table for user 'nmis', password 'nmis',

*** Install by  executing the sql commands in this script ***

shell> mysql -u root -p < nmis-event.sql

*/;

/*!40101 SET NAMES utf8 */;

/*!40101 SET SQL_MODE=''*/;

/* if this script has been run before, and you wish to start from scratch,
then need to drop user 'nmis' and reassign privilges.
Optionally, you can also delete the database 'nmis' , use at your own risk.
As no 'drop user if exist' exists, grant a harmless privilege to the user before dropping it.
This will create the user if it doesn`t exist, so that it can be dropped safely
Note v4.3.5 - drop nmis , for all host, and localhost, and recreate as nmis@localhost
*/;

/* optionally, drop the whole database */;
DROP DATABASE if exists nmis;
CREATE DATABASE if not exists nmis;

GRANT USAGE ON *.* TO `nmis`@`localhost`;					

DROP USER `nmis`@`localhost`;

CREATE USER `nmis`@`localhost`  IDENTIFIED BY 'nmis';


GRANT SELECT,INSERT,UPDATE,DELETE,CREATE,DROP ON nmis.* TO `nmis`@`localhost`;
FLUSH PRIVILEGES;
SET PASSWORD FOR `nmis`@`localhost` = PASSWORD('nmis');

USE nmis;

/*!40101 SET @OLD_SQL_MODE=@@SQL_MODE, SQL_MODE=`NO_AUTO_VALUE_ON_ZERO` */;

/*Table structure for table `event` */;
/*
`escalate`,`startdate`,`details`,`event`,`node`,`element
`,`index`,`level`,`ack`,`current`,`notify`
*/



DROP TABLE IF EXISTS `Events`;

CREATE TABLE `Events` (
  `startdate` varchar(12) NOT NULL,
  `lastchange` varchar(12) NOT NULL,
  `node` varchar(50) NOT NULL,
  `event` varchar(200) NOT NULL,
  `event_level` varchar(20) NOT NULL,
  `details` varchar(200) NOT NULL,
  `ack` varchar(5) NOT NULL,
  `escalate` tinyint(4) NOT NULL,
  `notify` varchar(50) NOT NULL,
  `index` varchar(300) NOT NULL,
  `element` varchar(200) NOT NULL,
  `current` varchar(200) NOT NULL,
  `level` varchar(200) NOT NULL,

PRIMARY KEY (`node`,`event`,`details`)
) ENGINE=InnoDB DEFAULT CHARSET=latin1 CHECKSUM=1 DELAY_KEY_WRITE=1 ROW_FORMAT=DYNAMIC;

/*!40101 SET SQL_MODE=@OLD_SQL_MODE */;




