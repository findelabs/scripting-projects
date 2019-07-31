#!/usr/bin/env bash

# Initialize array for search results
declare -A rloop

# Get array of args
args=($@)

# Get length of args array
arg_len=${#args[@]}

# Exit if too few args are passed
if [[ $arg_len -le 1 ]]
then
    echo "Please enter your args, followed by a trailing file to parse"
    exit 1
fi

# Get last arg
file=${args[$len-1]}

# Exit if $file does not exist
if [[ ! -e $file ]]
then
    echo "Could not access $file"
    exit 1
fi

# Get list of args ignoring the last arg
search_terms=${args[@]:0:${arg_len}-1}

# Loop over args
count=0
for i in ${search_terms[@]}
do
    if [[ $count == 0 ]]
    then
        # If we are on the first loop, then grep the file directly
        rloop[$count]=$(grep -i $i $file)
    else
        # Otherwise, grep the previous loop's content
        previous_loop=$((count-1))
        rloop[$count]=$(echo "${rloop[$previous_loop]}" | grep -i $i)
    fi
    count=$((count+1))
done

# Display search results
last_loop=$((count-1))
echo "${rloop[$last_loop]}"