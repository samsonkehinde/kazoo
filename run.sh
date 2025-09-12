#!/bin/bash -e
COMMAND=${1:-"console"}

NODE_NAME=${NODE_NAME:-kazoo}
COUCHDB=${COUCHDB:-couchdb}
COUCH_USR=${COUCH_USR:-admin}
COUCH_PWD=${COUCH_PWD:-admin}

RABBITMQ=${RABBITMQ:-rabbitmq}
RABBIT_USR=${RABBIT_USR:-guest}
RABBIT_PWD=${RABBIT_PWD:-guest}

KAZOO_APPS=${KAZOO_APPS:-acdc,sysconf,blackhole,callflow,cdr,conference,crossbar,fax,hangups,media_mgr,milliwatt,omnipresence,pivot,registrar,reorder,stepswitch,teletype,trunkstore,webhooks,ecallmgr}

export KAZOO_CONFIG=/opt/config.ini
sed -i "s|couchdb.kazoo|$COUCHDB|" $KAZOO_CONFIG
sed -i "s|rabbitmq.kazoo|$RABBITMQ|" $KAZOO_CONFIG
sed -i "s|.*username.*|username = ${COUCH_USR}|" $KAZOO_CONFIG
sed -i "s|.*password.*|password = ${COUCH_PWD}|" $KAZOO_CONFIG
sed -i "s|uri.*|uri = amqp://${RABBIT_USR}:${RABBIT_PWD}@${RABBITMQ}:5672|" $KAZOO_CONFIG

export KAZOO_NODE=$NODE_NAME@$(hostname)
export KAZOO_APPS=$KAZOO_APPS
export RELX_REPLACE_OS_VARS=true
export KZname="-name $KAZOO_NODE"

source ~/.bashrc
exec _rel/kazoo/bin/kazoo $COMMAND $*
