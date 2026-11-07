#!/bin/bash
for job in jobs/04_remove_dups/*.sh; 
do
    ./submit_short.sh "$job";
done