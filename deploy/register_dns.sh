#!/bin/bash

set -a
source .env
set +a

CONTENT_TYPE="Content-type: application/json"
CURL='/usr/bin/curl -k1 -X POST -d @-'
WAPI_URI="https://infoblox-gm.internal.sanger.ac.uk/wapi/v2.3.1/request"
JQ=/usr/bin/jq
 
if [ -z ${INFOBLOX_USER} ] ; then
 echo -n "Username: "
 read INFOBLOX_USER
fi
 
if [ -z ${INFOBLOX_PASS} ] ; then
 echo -n "Password: "
 read -s INFOBLOX_PASS
fi
echo ""
 
if [ -z $1 ] ; then
    echo "Need a json file to process"
    exit
fi
 
if ( ${JQ} . $1 >/dev/null ) ; then
    filled=$(sed "s/##HOST##/${DEPLOY_HOST}/g; s/##IP##/${DEPLOY_IP}/g" $1)
    echo "$filled" | $CURL -H "Content-type: application/json" -u ${INFOBLOX_USER}:${INFOBLOX_PASS} ${WAPI_URI}
else
    echo "Invalid JSON $1"
fi 