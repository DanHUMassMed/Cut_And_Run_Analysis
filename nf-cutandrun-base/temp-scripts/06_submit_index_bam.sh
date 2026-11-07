#!/bin/bash

for job in jobs/06_index_bam/*.sh; 
do
    ./submit_short.sh "$job";
done
