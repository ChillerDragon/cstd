#!/bin/bash
mkdir -p pastes
if [ "$1" == "dev" ]
then
    ./pstd_server.pl -l localhost:8080 -H localhost:8080 -v
else
    ./pstd_server.pl -l 149.202.127.134:8080 -H 149.202.127.134:8080
fi

