#!/bin/bash
mkdir -p pastes
if [ "$1" == "dev" ]
then
    ./pstd_server.pl -l localhost:8080 -H localhost:8080 -v
else
    ./pstd_server.pl -l 0.0.0.0:8080 -H paste.zillyhuhn.com
fi

