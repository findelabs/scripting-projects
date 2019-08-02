#!/usr/bin/env bash

trap kill_script INT TERM

####################
### DYNAMIC VARS ###
####################

count=0
parent=$$

# Used for server list
declare -a server_array

# Create the temp directory
tmpdir=$(mktemp -d)

# Specify files for info 
stdout_lock=$tmpdir/stdout
success=$tmpdir/success
failed=$tmpdir/failed
errors=$tmpdir/errors
tmpstdin=$tmpdir/tmpstdin
log_lock=$tmpdir/loglock
out_lock=$tmpdir/outlock

# Scriptname
scriptname=$(basename "$0")

# Declare logfile
logfile=/tmp/${USER}-$scriptname-$(date +%Y-%m-%d.%H-%M-%S).log

#################
### FUNCTIONS ###
#################

# This can be expanded if necessary. Currently will just call clean_up, but theoretically can be used to forcefully kill children
kill_script() {
    clean_up 1
}

# Usage
usage() {
    echo "
$0 [-psbuhH] [-t THREADS] [-l SERVERLIST] [-r FILE] -c COMMAND
    
    -p      Ask for user's password, to be used if the remote servers requires a password to login

    -s      Use sudo to execute the command passed. If -p is used, -s will use that password. If -p
            is not specified, then the script will as for the user's password

    -b      Brief mode: only show the first line of output to stdout, 
            but save full output to log
            
    -u      Unattended mode: Do not show output. Only return the final log location

    -t      Used to specify the number of threads to create

    -l      Specify the serverlist to run command on

    -r      BETA: Copy over a file to the remove servers

    -c      Command to run on the remote servers

    -H      Prefix the remote server name to the beginning of each line. Useful for large returns

    -h      Show this usage


Swarm Status Explanation:
[Active Threads/Thread Spawn Number     Success count/Error count/Failed count] Command Status, Servername, Command stdout 

Example Status:
[3/85 82/5/0] SUCCESS,testserver, 09:09:54 up 98 days, 11:48,  0 users,  load average: 0.29, 0.23, 0.14
"
    clean_up 2
}

clean_up() {

    # Clean up all directories created if script exits or is terminated

    # If no exit code is specified, exit 0
    if [[ -z $1 ]]
    then
        exit_code=0
    else
        exit_code=$1
    fi

    # Remove the temporary directory
    if [[ -d $tmpdir ]]
    then
        rm -r $tmpdir
    fi

    # Exit with proper exit code
    exit $exit_code
}

ask () {
    while true
    do
        if [ "${2:-}" = "Y" ]
        then
            prompt="Y/n"
            default=Y
        elif [ "${2:-}" = "N" ]
        then
            prompt="y/N"
            default=N
        else
            prompt="y/n"
            default=
        fi
        
        # Get user input
        read -p "$1 [$prompt] " REPLY </dev/tty

        if [ -z "$REPLY" ]
        then
            REPLY=$default
        fi
        case "$REPLY" in
            Y*|y*) return 0 ;;
            N*|n*) return 1 ;;
        esac
    done
}

ping_test() {

    # Function to get return code from ping.
    # 0: success
    # 1: unpingable
    # 2: unresolvable

    ping -c 1 -w 1 $1 >/dev/null 2>&1
    echo $?
}

stdout_log() {

    # Send ssh cargo to stdout
    
    local job_status=$1
    local job_number=$2
    local job_server=$3
    local job_cargo=$4

    if [[ $mode != "unattended" ]]
    then
        # Get count of successful jobs
        local success_count=$(wc -l $success 2>/dev/null | awk '{print $1}')
        [[ $success_count == "" ]] && success_count=0

        # Get count of failed jobs
        local fail_count=$(wc -l $failed 2>/dev/null | awk '{print $1}')
        [[ $fail_count == "" ]] && fail_count=0

        # Get count of error'd jobs
        local error_count=$(wc -l $errors 2>/dev/null | awk '{print $1}')
        [[ $error_count == "" ]] && error_count=0

        # Get count of active children, subtract 1 to get count of only children
        local active=$(ps xao ppid | grep -w -c $parent) 
        if [[ $active -gt 1 ]]
        then
            ((active--))
        fi

        if [[ $count == 0 ]]
        then
            # Display the whole result for first round
            echo [$active/$job_number $success_count/$error_count/$fail_count] $job_status,$job_server,"$job_cargo"
        elif [[ $mode == "brief" ]]
        then
            # Only display the first line of ssh cargo
            if [[ $job_status == "SUCCESS" ]]
            then
                # echo with green is job succeeded
                echo -e "\e[32m""[$active/$job_number $success_count/$error_count/$fail_count] $job_status,$job_server,""\e[0m${job_cargo%%$'\n'*}"
            elif [[ $job_status == "FAILED" ]]
            then
                # echo with red if job failed
                echo -e "\e[91m""[$active/$job_number $success_count/$error_count/$fail_count] $job_status,$job_server,""\e[0m${job_cargo%%$'\n'*}"
            else
                # echo with yellow if job error'd
                echo -e "\e[93m""[$active/$job_number $success_count/$error_count/$fail_count] $job_status,$job_server,""\e[0m${job_cargo%%$'\n'*}"
            fi
        elif [[ $mode != "unattended" ]]
        then
            if [[ $job_status == "SUCCESS" ]]
            then
                # echo with green is job succeeded
                echo -e "\e[32m""[$active/$job_number $success_count/$error_count/$fail_count] $job_status,$job_server,""\e[0m$job_cargo"
            elif [[ $job_status == "FAILED" ]]
            then
                # echo with red if job failed
                echo -e "\e[91m""[$active/$job_number $success_count/$error_count/$fail_count] $job_status,$job_server,""\e[0m$job_cargo"
            else
                # echo with yellow if job error'd
                echo -e "\e[93m""[$active/$job_number $success_count/$error_count/$fail_count] $job_status,$job_server,""\e[0m$job_cargo"
            fi
                
        fi 
    fi
}

store_results () {

    # Save ssh cargo to the log

    job_status=$1
    job_number=$2
    job_server=$3
    job_cargo=$4

    if [[ -e $logfile ]]
    then
        (( flock -x 300
          echo $job_status $job_number,$job_server,"$job_cargo" >> $logfile
        ) 300>$log_lock )
    fi
}

ssh_command() {

    # Actual command to run commands on servers

    local job_number=$1
    local job_server=${server_array[$1]::-1}

    ping_rc=$(ping_test $job_server)
    if [[ $ping_rc == 0 ]]
    then 
        if [[ $askpass == "true" ]] || [[ $usesudo == "true" ]]
        then
            if [[ $usesudo == "true" ]]
            then
                sshpass -p "$mypass" scp -q -o ConnectTimeout=5 $shadow_filepath $job_server:/tmp 2>dev/null
                scp_rc=$?
                if [[ $scp_rc -eq 0 ]]
                then
                    cargo=$(sshpass -p "$mypass" ssh -tt -q -o ConnectTimeout=5 -o StrictHostKeyChecking=no $job_server "openssl enc -base64 -aes-256-cbc -d -in /tmp/$shadow_filename -k $random_key | sudo -p \"\" -S $command; rc=$?; test -f /tmp/$shadow_filename && rm /tmp/$shadow_filename; exit \$rc" 2>/dev/null)
                fi
            else
                cargo=$(sshpass -p "$mypass" ssh -q -o ConnectTimeout=5 -o StrictHostKeyChecking=no $job_server $command 2>/dev/null)
            fi
        else
            cargo=$(ssh -q -o PasswordAuthentication=no -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o BatchMode=yes $job_server $command 2>/dev/null)
        fi
        if [[ $scp_rc == 0 ]]
        then
            ssh_rc=$?
        else
            ssh_rc=300
        fi

        # Prepend hostname if using hostname_prefix
        if [[ $hostname_prefix == "true" ]]
        then
            cargo=$(echo; echo "$cargo" | sed -e "s/^/$job_server,/")
        fi

        if [[ -e $tmpdir ]]
        then
            case $ssh_rc in
                0) status=SUCCESS; echo $job_server >> $success;; 
                1) status=FAILED; echo $job_server >> $failed;; 
                300) status=FAILED-SCP; echo $job_server >> $failed;;
                255) status=FAILED-SSH; echo $job_server >> $errors;; 
                *) status="FAILED($ssh_rc)"; echo $job_server >> $failed;;
            esac
        fi
    else
        if [[ -e $tmpdir ]]
        then
            case $ping_rc in 
                1) status=UNPINGABLE; echo $job_server >> $errors;;
                2) status=FAILED-DNS; echo $job_server >> $errors;;
                *) status="PING-ERROR($ping_rc)"; echo $job_server >> $errors;;
            esac 
        fi
    fi

    # Send the ssh results to stdout
    stdout_log "$status" "$job_number" "$job_server" "$cargo" 

    # Send the ssh results to the log
    store_results $status $job_number $job_server "$cargo" 

    if [[ $job_number == 0 ]]; then
        ((count++))
    fi
}

rsync_data() {
    
    # Place holder in case we eventually want to send scripts to execute

    echo rsyncing data now
}

seed() {

    # Start ssh process on server

    local job_server=${server_array[$1]::-1}

    ping_rc=$(ping_test $job_server)
    if [[ $ping_rc == 1 ]]
    then
        status=UNPINGABLE
        echo $job_server >> $errors
        stdout_log "$status" "$count" "$job_server" 
        store_results "$status" "$count" "$job_server" 
    elif [[ $ping_rc == 2 ]]
    then
        status=FAILED-DNS
        echo $job_server >> $errors
        stdout_log "$status" "$count" "$job_server"
        store_results "$status" "$count" "$job_server"
    elif [[ $ping_rc ]]
    then
    # Again, a placeholder var. Eventually rsync and ssh should be interchangable
    #    rsync_rc=$(rsync_data $1) 
        rsync_rc=0
        if [[ $rsync_rc == 1 ]]
        then
            status=FAILED-RSYNC
            echo $job_server >> $errors
        elif [[ $rsync_rc == 0 ]]
        then
            ssh_command $1
        else
            status=RSYNC-ERROR
            echo $job_server >> $errors
        fi
    else
        echo "Experienced error pinging $job_server"
        echo $job_server >> $errors
    fi
}

spawn_seeds() {

    # Controls how seeds are started and controlled

    starttime=$(date +%s)
    batch=0
    while [ $count -lt $total ]
    do
        if [[ $batch_start -gt 0 ]]
        then
            while [[ $batch_start -gt 0 ]] && [[ $count -lt $total ]]
            do
                seed $count &
                ((count++))
                ((batch_start--))
            done
        else
            current_jobs=$(jobs -p | wc -l)
            if [[ $current_jobs -lt $threads ]]
            then
                batch_start=$(echo "$threads - $current_jobs | bc")
            else
                sleep 0.01
            fi
        fi
    done
    touch $tmpdir/seeds_complete 
} 

first_seed() {

    # This is used to ensure that the command acts as expected

    echo -e "you are about to run \e[32m$command\e[0m on \e[32m$total servers\e[0m, using \e[32m$threads threads.\e[0m Here are the first 10:"
    echo
    for i in $(echo ${server_array[@]:0:10})
    do
        echo $i
    done
    echo
    echo -e "We will run \e[32m$command\e[0m on \e[32m$(echo -n ${server_array[0]})\e[0m before the rest of the list to be safe"
    if ask "Are you sure you want to continue?" Y;then
        echo "Running $command on $serverlist $(date)" >> $logfile
        seed 0
        if ask "Are you sure you want to continue?" Y
        then
            spawn_seeds
        else
            kill_script
        fi
    else
        kill_script 
    fi
}

stats() {

    # Show stats at the conclusion of run

    endtime=$(date +%s)
    if [[ $starttime == $endtime ]]
    then
        deltatime=0
        average=$total
    else
        deltatime=$(echo $endtime - $starttime | bc)
        average=$(echo "$total / $deltatime" | bc)
    fi
    echo
    echo "Ran on $total servers in $deltatime seconds, average of $average hosts/second"
    echo "Un-SSH-able count = $(grep -c 'FAILED-SSH ' $logfile)"
    echo "Unpingable count = $(grep -c 'UNPINGABLE ' $logfile)"
    echo "DNS Failure count = $(grep -c 'FAILED-DNS ' $logfile)"
    echo "Success count = $(grep -c 'SUCCESS ' $logfile)"
    echo "Failed count = $(grep -c 'FAILED \|FAILED(' $logfile)"
    echo
    echo "$logfile"
}

###############
### GETOPTS ###
###############

while getopts "c:t:l:r:psubhH" opt; do
    case $opt in
        u)
            mode=unattended
            ;;
        b)
            mode=brief
            ;;
        c)
            command=$OPTARG
            ;;
        t)
            if [ "$OPTARG" -eq "$OPTARG" ] 2>/dev/null; then
                threads=$OPTARG
            else
                echo "Please specify a number for threads"
                clean_up 1
            fi
            ;;
        l)
            serverlist=$OPTARG
            ;;
        r)
            rsync_file=$OPTARG
            ;;
        p)
            askpass=true
            ;;
        s)
            usesudo=true
            ;;
        h)
            usage
            ;;
        H)
            hostname_prefix=true
            ;;
        *)
            echo "invalid option: -$OPTARG"
            usage
            ;;
    esac
done

##################
### PRE CHECKS ###
##################

if [[ -z $command ]]
then
    echo "Please specify a command with -c"
    usage
    clean_up 1
fi

if [[ -z $threads ]]
then
    threads=10
fi

if [[ $threads != $threads ]]
then
    echo "Please specify a number with -t"
    usage
    clean_up 1
fi

if [[ $threads == 0 ]]
then
    echo "Please specify a number between 1-100"
    usage
    clean_up 1
fi

if [ ! -t 0 ]
then
    while IFS= read -r line; do
        echo "$line" | awk -F, '{print $1}' >> $tmpstdin
    done
    serverlist=$tmpstdin
fi

if [[ -z $serverlist ]]
then
    echo "Please provide server list with -l"
    usage
    clean_up 1
fi

if [[ -f $serverlist ]]
then
    serverlist_filtered=$(cat $serverlist | sed '/^$/d' | grep -v "\[")
    total=$(echo "$serverlist_filtered" | wc -l)
    mapfile server_array < <(echo "$serverlist_filtered")
else
    echo "Could not access $serverlist"
    clean_up 1
fi

if [[ -n $rsync_file ]]
then
    if [[ ! -e $rsync_file ]]; then
        echo "Please specify an accessible file"
        usage
        clean_up 1
    fi
fi

if [[ $askpass == "true" ]] || [[ $usesudo == "true" ]]
then
    if [[ $usesudo == "true" ]]
    then
        string="sudo/ssh password"
    else
        string="ssh password"
    fi
    read -s -p "[$string]: " mypass </dev/tty
    echo
    if [[ $mypass == "" ]]
    then
        echo "please enter a password"
        clean_up 1
    fi

fi

if [[ $usesudo == "true" ]]
then
    random_key=$(openssl rand -base64 32)
    shadow_filepath=$(mktemp --tmpdir=$tmpdir)
    shadow_filename=$(echo $shadow_filepath | awk -F/ '{print $NF}')

    # Save sudo password to salted file
    echo $mypass | openssl enc -base64 -aes-256-cbc -salt -out $shadow_filepath -k $random_key
fi

#################
### MAIN LOOP ###
#################


if [[ $mode != "unattended" ]]; then
    first_seed 
else
    spawn_seeds
fi
wait

# Save last to log
if [[ -e $logfile ]]
then
    ( flock -x 300
    echo "finished: $(date)" >> $logfile
    ) 300>$log_lock
fi

if [[ $mode != "unattended" ]]; then
    stats
else
    echo $logfile
fi
clean_up 
