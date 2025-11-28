#!/bin/bash

log() {
        local ts="$(date '+%F_%H-%M')"
        printf '[%s][*] %s\n' "$ts" "$1" | tee -a ~/start_pstd.log
}

log "starting pstd ..."

mkdir -p pastes
if [ "$1" == "dev" ]
then
        log "starting in dev mode"
        if ! ./pstd_server.pl -l localhost:8080 -H localhost:8080 -v
        then
                log "failed to start. exit code: $?"
        else
                log "started OK"
        fi
else
        log "starting in prod mode"
        if ! ./pstd_server.pl -l 0.0.0.0:8080 -H paste.zillyhuhn.com
        then
                log "failed to start. exit code: $?"
        else
                log "started OK"
        fi
fi
