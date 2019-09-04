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

# Set default ssh port
default_sshport=22

# Required programs
required="flock"

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
$scriptname [-psbuhS] [-J PROXY_HOSTNAME[:PORT]] [-P PORT] [-t THREADS] [-l SERVERLIST] -c COMMAND
    
    -b      Brief mode: only show the first line of output to stdout, 
            but save full output to log
            
    -c      Command to run on the remote servers

    -h      Show this usage

    -J      Utilize a proxy (Jump) host to connect to the remote servers. Format would be servername[:port]

    -l      Specify the serverlist to run command on

    -p      Ask for user's password, to be used if the remote servers requires a password to login

    -P      Specify ssh port to use. Default is 22

    -s      Use sudo to execute the command passed. If -p is used, -s will use that password. If -p
            is not specified, then the script will as for the user's password

    -S      Show stats at the end of the script

    -t      Threads to create

    -u      Use a specific username, instead of current logged-in user

    -U      Unattended mode: Do not show output. Only return the final log location


Swarm Status Explanation:
Command Status: [Server Hostname] [Active Threads/Thread Spawn Number - Success/Error/Failed count]: Command Stdout 

Example Status:
ok: [testserver] [3/85 82/5/0]: 09:09:54 up 98 days, 11:48,  0 users,  load average: 0.29, 0.23, 0.14
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
    local job_error=$2
    local job_number=$3
    local job_server=$4
    local job_cargo=$5

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
            echo $job_status: [$job_server] [$active/$job_number $success_count/$error_count/$fail_count]: $job_error: "$job_cargo"
        elif [[ $mode == "brief" ]]
        then
            # Only display the first line of ssh cargo
            if [[ $job_status == "ok" ]]
            then
                # echo with green is job succeeded
                echo -n -e "\e[32m""$job_status: [$job_server] [$active/$job_number $success_count/$error_count/$fail_count]:""\e[0m"; echo "${job_cargo%%$'\n'*}"
            elif [[ $job_error == "FAILED" ]]
            then
                # echo with red if job failed
                echo -n -e "\e[91m""$job_status: [$job_server] [$active/$job_number $success_count/$error_count/$fail_count]:""\e[0m"; echo "${job_cargo%%$'\n'*}"
            else
                # echo with yellow if job error'd
                echo -n -e "\e[93m""$job_status: [$job_server] [$active/$job_number $success_count/$error_count/$fail_count]: $job_error""\e[0m"; echo "${job_cargo%%$'\n'*}"
            fi
        elif [[ $mode != "unattended" ]]
        then
            if [[ $job_status == "ok" ]]
            then
                # echo with green is job succeeded
                echo -n -e "\e[32m""$job_status: [$job_server] [$active/$job_number $success_count/$error_count/$fail_count]:""\e[0m"; echo "$job_cargo"
            elif [[ $job_error == "FAILED" ]]
            then
                # echo with red if job failed
                echo -n -e "\e[91m""$job_status: [$job_server] [$active/$job_number $success_count/$error_count/$fail_count]:""\e[0m"; echo "$job_cargo"
            else
                # echo with yellow if job error'd
                echo -n -e "\e[93m""$job_status: [$job_server] [$active/$job_number $success_count/$error_count/$fail_count]: $job_error""\e[0m"; echo "$job_cargo"
            fi
                
        fi 
    fi
}

store_results () {

    # Save ssh cargo to the log

    job_status=$1
    job_error=$2
    job_number=$3
    job_server=$4
    job_cargo=$5

    if [[ -e $logfile ]]
    then
        flock $log_lock echo $job_status: [$job_server] $job_error:"$job_cargo" >> $logfile
    fi
}

ssh_command() {

    # Actual command to run commands on servers

    local job_number=$1
    local job_server=${server_array[$1]}
    local cargo=

    ping_rc=$(ping_test $job_server)
    if [[ $ping_rc == 0 ]]
    then 
        if [[ $askpass == "true" ]] || [[ $usesudo == "true" ]]
        then
            if [[ $usesudo == "true" ]]
            then
                scp_attempts=0
                while [ $scp_attempts -lt 3 ]
                do
                    if [[ -n $proxy_host ]]
                    then
                        sshpass -p "$mypass" scp -P $sshport -q -o ConnectTimeout=5 -o StrictHostKeyChecking=no $extra_scp_opts $shadow_filepath ${user}@${job_server}:/tmp 2>/dev/null
                    else
                        sshpass -p "$mypass" scp -P $sshport -q -o ConnectTimeout=5 -o StrictHostKeyChecking=no $shadow_filepath ${user}@${job_server}:/tmp 2>/dev/null
                    fi
                    scp_rc=$?
                    if [[ $scp_rc -gt 0 ]]
                    then
                        scp_attempts=$(($scp_attempts + 1))
                        sleep 1
                    else
                        break
                    fi
                done
                if [[ $scp_rc -eq 0 ]]
                then
                    cargo=$(sshpass -p "$mypass" ssh -tt -l $user -p $sshport -q -o ConnectTimeout=5 -o StrictHostKeyChecking=no $extra_ssh_opts $job_server "openssl enc -base64 -aes-256-cbc -d -in /tmp/$shadow_filename -k $random_key | sudo -p \"\" -S $command; rc=\$?; test -f /tmp/$shadow_filename && rm /tmp/$shadow_filename; exit \$rc" 2>/dev/null)
                fi
            else
                cargo=$(sshpass -p "$mypass" ssh -l $user -p $sshport -q -o ConnectTimeout=5 -o StrictHostKeyChecking=no $extra_ssh_opts $job_server $command 2>/dev/null)
            fi
        else
            cargo=$(ssh -l $user -p $sshport -q -o PasswordAuthentication=no -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o BatchMode=yes $extra_ssh_opts $job_server $command 2>/dev/null)
        fi
        ssh_rc=$?
        if [[ -n $scp_rc ]] && [[ $scp_rc != 0 ]]
        then
            ssh_rc=300
        fi

        # Prepend hostname if ssh command output is more than one line
        if [[ $(echo "$cargo" | wc -l) -gt 1 ]]
        then
            cargo=$(echo; echo "$cargo" | sed -e "s/^/$job_server,/")
        fi

        if [[ -e $tmpdir ]]
        then
            case $ssh_rc in
                0) status=ok;      error=SUCCESS;           echo $job_server >> $success;; 
                1) status=fail;    error=FAILED;            echo $job_server >> $failed;; 
                300) status=error; error=FAILED-SCP;        echo $job_server >> $failed;;
                255) status=error; error=FAILED-SSH;        echo $job_server >> $errors;; 
                *) status=error;   error="failed($ssh_rc)"; echo $job_server >> $failed;;
            esac
        fi
    else
        if [[ -e $tmpdir ]]
        then
            case $ping_rc in 
                1) status=error; error=UNPINGABLE;              echo $job_server >> $errors;;
                2) status=error; error=FAILED-DNS;              echo $job_server >> $errors;;
                *) status=error; error="FAILED-PING($ping_rc)"; echo $job_server >> $errors;;
            esac 
        fi
    fi

    # Send the ssh results to stdout
    stdout_log "$status" "$error" "$job_number" "$job_server" "$cargo" 

    # Send the ssh results to the log
    store_results $status $error $job_number $job_server "$cargo" 

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
    # This is where any actions right before the command is ran would take place
    local job_server=${server_array[$1]::-1}
    ssh_command $1
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
                batch_start=$(($threads - $current_jobs))
            else
                sleep 0.01
            fi
        fi
    done
    touch $tmpdir/seeds_complete 
} 

first_seed() {

    # This is used to ensure that the command acts as expected
    if [[ -n $proxy_host ]]
    then
        echo -e "You are about to run \e[32m$command\e[0m on \e[32m$total servers\e[0m, with \e[32m$proxy_hostname\e[0m as the jump host, and using \e[32m$threads threads.\e[0m Here are the first 10:"
    else
        echo -e "You are about to run \e[32m$command\e[0m on \e[32m$total servers\e[0m, using \e[32m$threads threads.\e[0m Here are the first 10:"
    fi
    echo
    for i in $(echo ${server_array[@]:0:10})
    do
        echo $i
    done
    echo
    echo -e "We will run \e[32m$command\e[0m on \e[32m$(echo -n ${server_array[0]})\e[0m before the rest of the list to be safe"
    if ask "Are you sure you want to continue?" Y;then
        echo "Running $command on $serverlist on $(date)" >> $logfile
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
        deltatime=$(($endtime - $starttime))
        average=$(($total / $deltatime))
    fi
    echo
    echo "Ran on $total servers in $deltatime seconds, average of $average hosts/second"
    echo "Un-SSH-able count = $(grep -c 'FAILED-SSH:' $logfile)"
    echo "Unpingable count = $(grep -c 'UNPINGABLE:' $logfile)"
    echo "DNS Failure count = $(grep -c 'FAILED-DNS:' $logfile)"
    echo "Success count = $(grep -c '^ok:' $logfile)"
    echo "Failed count = $(grep -c 'failed:\|failed(' $logfile)"
    echo
    echo "$logfile"
}

###############
### GETOPTS ###
###############

while getopts "c:t:l:r:pP:sbhSJ:u:U" opt; do
    case $opt in
        U)
            mode=unattended
            ;;
        b)
            mode=brief
            ;;
        c)
            command=$OPTARG
            ;;
        t)
            threads=$OPTARG
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
        P)
            sshport=$OPTARG
            ;;
        s)
            usesudo=true
            ;;
        h)
            usage
            ;;
        J)
            proxy_host=$OPTARG
            ;;
        S)
            show_stats=true
            ;;
        u)
            user=$OPTARG
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

# Check for required programs
for program in $required
do
    command -v $program >/dev/null 2>&1
    if [[ $? != 0 ]]
    then
        echo "Could not find required $program, exiting"
        exit 1
    fi 
done

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

if [[ -n $threads ]] && ! [ $threads -eq $threads ] 2>/dev/null
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

if [[ -n $sshport ]] 
then
    if ! [ "$sshport" -eq "$sshport" ] 2>/dev/null
    then
        echo "Please specify a correct port number"
        usage
        clean_up 1
    fi
else
    sshport=$default_sshport
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
    while read line
    do
        server_array[i]="$line"
        i=$((i + 1))
    done < <(echo "$serverlist_filtered")
    total=${#server_array[@]}
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

if [[ -n $proxy_host ]]
then
    # Split up proxy hostname and proxy port
    proxy_hostname=$(echo $proxy_host | awk -F: '{print $1}')
    proxy_port=$(echo $proxy_host | awk -F: '{print $2}')

    # Ping test proxy hostname
    proxy_hostname_check=$(ping_test $proxy_hostname)

    # Fail if proxy is unpingable or unresolvable
    if [[ $proxy_hostname_check == 1 ]]
    then
        echo "error, $proxy_hostname is not pingable"
        clean_up 1
    elif [[ $proxy_hostname_check == 2 ]]
    then
        echo "error, could not resolve $proxy_hostname"
        clean_up 1
    fi

    # If -w was not passed with a port, just use 22
    if [[ -z $proxy_port ]]
    then
        proxy_port=22
    fi

    # test ssh connection to specified proxy
    ssh -l $user -p $proxy_port -q -o PasswordAuthentication=no -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o BatchMode=yes $proxy_hostname exit 2>/dev/null
    proxy_ssh_rc=$?

    # If proxy ssh test failed, then exit
    if [[ $proxy_ssh_rc -gt 0 ]]
    then
        echo "error, connecting to $proxy_hostname on port $proxy_port failed with return code $proxy_ssh_rc"
        clean_up 1
    else
        extra_ssh_opts="-J $proxy_hostname:$proxy_port"
        extra_scp_opts="-oProxyJump=$proxy_hostname:$proxy_port"
    fi
fi

# If user did not specify a user with a -u, use the logged in username
if [[ -z $user ]]
then
    user=$USER
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
    flock $log_lock echo "Finished: $(date)" >> $logfile
fi

if [[ $mode != "unattended" ]] && [[ $show_stats == "true" ]]; then
    stats
else
    echo
    echo $logfile
fi
clean_up 
