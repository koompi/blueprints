#!/bin/bash

mkdir -p out

parameters="-- --minimal"
if [ $# -gt 0 ]; then parameters="$@"; fi

docker build -t pionuxos/blueprints .
docker run --privileged --rm \
        -v /var/cache:/var/cache \
        -v "$(pwd)":/var/pionux \
        -ti pionuxos/blueprints ${parameters}
