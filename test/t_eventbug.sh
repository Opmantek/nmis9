#!/bin/sh

cp /usr/local/nmis8/var/nmis-event.nmis ~nmis/event1.nmis
cp /usr/local/nmis8/var/xandist1-node.nmis ~nmis/node1.nmis
/usr/local/nmis8/bin/nmis.pl node=xandist1 type=update debug=1 > ~nmis/update1.txt
cp /usr/local/nmis8/var/nmis-event.nmis ~nmis/event2.nmis
cp /usr/local/nmis8/var/xandist1-node.nmis ~nmis/node2.nmis
/usr/local/nmis8/bin/nmis.pl node=xandist1 type=collect debug=1 > ~nmis/collect1.txt
cp /usr/local/nmis8/var/nmis-event.nmis ~nmis/event3.nmis
cp /usr/local/nmis8/var/xandist1-node.nmis ~nmis/node3.nmis
/usr/local/nmis8/bin/nmis.pl node=xandist1 type=collect debug=1 > ~nmis/collect2.txt
cp /usr/local/nmis8/var/nmis-event.nmis ~nmis/event4.nmis
cp /usr/local/nmis8/var/xandist1-node.nmis ~nmis/node4.nmis

