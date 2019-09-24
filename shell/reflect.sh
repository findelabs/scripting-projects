#!/bin/sh

# This script is used to baseline config files against a default repository
# The repository should be a git repo, specified with the git_repo variable
# Configs for server are stored within the git repo using the following structure:
#
# This is a very rough draft at this time, and should not be used anywhere important
#
# Repo Root:
#   hosts:
#     HOSTNAME:
# 
#   groups:
#     - default
#
#   files:
#     :
#       
#   services:
#     - unbound.sh
#     - httpd.sh
#     - pf.conf
#
# This script requires the following environmental variables to be set for gitlab access:
#
# REFLECT_GIT_SERVER
# REFLECT_GIT_REPO
# REFLECT_GIT_USER
# REFLECT_GIT_TOKEN

### VARIABLES ###

HOSTNAME=$(hostname -s)

# Create a temp directory
tmpdir=$(mktemp -d)

repo_hosts="$tmpdir/hosts"
repo_groups="$tmpdir/groups"
repo_files="$tmpdir/files"


### FUNCTIONS ###

log() {
    message="$1"
    echo "$message"
    logger -t reflect "$message" 
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
        rm -rf $tmpdir
    fi

    # Exit with proper exit code
    exit $exit_code
}

sync_group() {
    group="$1"

    log "Syncing $group:"
    grep ^file, $repo_groups/$group | column -s, -t 
    echo
    echo "Actions:"

    while read line
    do
        type=$(echo $line | cut -d, -f1)
        src=$(echo $line | cut -d, -f2)
        dest=$(echo $line | cut -d, -f3)
        user=$(echo $line | cut -d, -f4)
        group=$(echo $line | cut -d, -f5)
        mode=$(echo $line | cut -d, -f6)
        service=$(echo $line | cut -d, -f7)

        if [ "$type" = "file" ]
        then
            sync_file $src $dest 
            sync_user_group $dest $user $group
            sync_mode $dest $mode
        fi
    done < ${repo_groups}/$group
}

sync_file() {
    src="${repo_files}/$1"
    dest="$2"

    if [ -f "$src" ]
    then
        if [ "$(md5 $src | awk '{print $NF}')" != "$(md5 $dest | awk '{print $NF}')" ]
        then
            cp -f $src $dest
            rc=$?
            if [ "$rc" = "0" ]
            then
                log "Sync'd $dest"
            else
                log "Failed to sync $dest"
            fi
        fi
    else
        log "$src does not exist"
    fi
}

sync_user_group() {
    dest="$1"
    user="$2"
    group="$3"

    if [ -f "$dest" ]
    then
        if [ "${user}:${group}" != "$(stat $dest | awk '{print $5":"$6}')" ]
        then
            chown ${user}:${group} $dest
            rc=$?
            if [ "$rc" = "0" ]
            then
                log "Applied ${user}:${group} permissions to $dest"
            else
                log "Failed applying user permissions to $dest"
            fi
        fi
    else
        log "$dest does not exist"
    fi
}

sync_mode() {
    dest="$1"
    mode="$2"

    if [ -f "$dest" ]
    then
        if [ "$mode" != "$(stat -f '%p' $dest | tail -c 4)" ]
        then
            chmod ${mode} $dest
            rc=$?
            if [ "$rc" = "0" ]
            then
                log "Applied ${mode} permissions to $dest"
            else
                log "Failed applying permissions to $dest"
            fi
        fi
    else
        log "$dest does not exist"
    fi
}


### SETUP ###

if [ -z "$REFLECT_GIT_USER" ]
then
    echo "Missing REFLECT_GIT_USER"
    precheck_fail="true"
fi
if [ -z "$REFLECT_GIT_TOKEN" ]
then
    precheck_fail="true"
    echo "Missing REFLECT_GIT_TOKEN"
fi
if [ -z "$REFLECT_GIT_SERVER" ]
then
    echo "Missing REFLECT_GIT_SERVER"
    precheck_fail="true"
fi
if [ -z "$REFLECT_GIT_REPO" ]
then
    echo "Missing REFLECT_GIT_REPO"
    precheck_fail="true"
fi
if [ "$precheck_fail" = "true" ]
then
    exit 1
fi

# Clone the repo containing the configs
git clone -q https://${REFLECT_GIT_USER}:${REFLECT_GIT_TOKEN}@${REFLECT_GIT_SERVER}/${REFLECT_GIT_REPO} $tmpdir




############
### MAIN ###
############

# Check if HOSTNAME is in hosts folder
if [ -f "${repo_hosts}/$HOSTNAME" ]
then
    . ${repo_hosts}/$HOSTNAME
    echo "host groups: $groups"
    echo
else
    echo "$HOSTNAME not found in configs"
    clean_up
fi

# Go through each group and list the files to be pulled into server
for group in $(echo $groups | tr ',' ' ')
do
    if [ -f "${repo_groups}/${group}" ]
    then
        sync_group $group
    else
        echo "Group $group is missing from groups folder"
    fi
done


clean_up
