#!/bin/bash

for job in jobs/03_align/*.sh; 
do
    ./submit_short.sh "$job"; 
done