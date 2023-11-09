#!/bin/bash

GROUP=$1

for node in `/usr/local/nmis9/admin/node_admin.pl act=list group=$GROUP`
    do 
    /usr/local/nmis9/admin/node_admin.pl act=set node=$node entry.configuration.customer="FirstWave opDev" entry.configuration.customer_contact="FCT opDev" entry.configuration.customer_id=DEV-098765 entry.configuration.service_level=Aluminium
    #/usr/local/nmis9/admin/node_admin.pl act=set node=$node entry.configuration.customer="FirstWave" entry.configuration.customer_contact="FCT DevOps" entry.configuration.customer_id=FCT-123456
done
