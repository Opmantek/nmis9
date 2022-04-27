#!/bin/sh

# ssl_expiry_check.sh - Script to check SSL certificate expiry

# Returns a value suitable for NMIS Service Monitoring
# 0, 50 or 100 depending on status, as per https://community.opmantek.com/display/NMIS/Service+Monitoring+Examples
# If expires is greater than 30 days, PASS (return 100)
# If expires is between 30 and 7 days, WARN (return 50)
# If expires is less than 7 days, FAIL (return 0)

# Useage ./ssl_expiry_check.sh $host:$port
# Eg: ./ssl_expiry_check.sh www.opmantek.com:443

# Set debug to anything to see more output (not set in production).

host=$1

if [ -z "$host" ]; then
    host="www.opmantek.com:443"
fi

debug=""

expires=`echo | openssl s_client -showcerts -connect "$host" 2>/dev/null | openssl x509 -noout -text 2>/dev/null | grep "Not After" | cut -d: -f2- | { read gmt ; date -d "$gmt" --utc +"%Y%m%d" ; }`

today=`date --utc +"%Y%m%d"`

days_to_expiry=`echo $(( ($(date --date="$expires" +%s) - $(date --date="$today" +%s) )/(60*60*24) ))`

# print this as the status regardless
if [ -n "$debug" ]; then
    echo "Days To Expiry: $days_to_expiry"
else
    echo "Days To Expiry: $days_to_expiry"
fi

if [ -n "$debug" ]; then
    echo "Expires: $expires"
fi

if [ -n "$debug" ]; then
    echo "Today: $today"
fi

if [ "$days_to_expiry" -gt 29 ]; then
    if [ -n "$debug" ]; then
        echo "PASS"
    fi
    exit 100
elif [ "$days_to_expiry" -gt 7 ]; then
    if [ -n "$debug" ]; then
        echo "WARNING"
    fi
    exit 50
else
    if [ -n "$debug" ]; then
        echo "FAIL"
    fi
    exit 0
fi

