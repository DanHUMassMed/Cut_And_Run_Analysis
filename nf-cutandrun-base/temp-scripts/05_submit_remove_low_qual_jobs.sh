#!/bin/bash

for job in jobs/05_mapq_filter/*.sh; 
do
    ./submit_short.sh "$job";
done