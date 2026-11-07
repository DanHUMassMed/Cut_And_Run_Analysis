#!/bin/bash
for job in jobs/07_ucsc/*.sh;
do
    ./submit_short.sh "$job";
done