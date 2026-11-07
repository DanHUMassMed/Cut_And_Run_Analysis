#!/bin/bash
SCRIPT=$1

if [ "$SCRIPT" = "" ]; then
    echo "You must pass a script.sh file as a parameter."
else
    # -o: Standard output log
    # -e: Error log
    # %J: LSF variable that inserts the Job ID into the filename
    bsub -q short \
         -W 6:00 \
         -n 4 \
         -R "rusage[mem=16GB]" \
         -o "${SCRIPT}.out.%J" \
         -e "${SCRIPT}.err.%J" \
         ./$SCRIPT
fi

