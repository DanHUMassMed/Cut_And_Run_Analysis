#!/bin/bash
for job in jobs/08_bigwig/*.sh; do
  ./submit_short.sh "$job"
done
