#!/bin/bash

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_DIR="${SCRIPT_DIR}/.cronstate"
mkdir -p "${STATE_DIR}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

DISABLED_TAG="#CRONSS_DISABLED:"

# Default values
SSH_PORT=22
SSH_USER=$(whoami)
SSH_HOST=""
SSH_IDENTITY=""
DOCKER_CONTAINER=""
LOCAL_MODE=0
JSON_OUTPUT=0

usage() {
    cat << EOF
Usage: $0 [OPTIONS] COMMAND

Manage cronjobs on remote servers via SSH, locally, or inside Docker containers.
Supports state tracking for maintenance windows.

OPTIONS:
    -h, --host HOST         SSH host (or use CRON_HOST env var)
    -u, --user USER         SSH user (or use CRON_USER env var, default: current user)
    -p, --port PORT         SSH port (or use CRON_PORT env var, default: 22)
    -i, --identity FILE     SSH identity file (or use CRON_IDENTITY env var)
    --docker CONTAINER      Target a running Docker container (bypasses SSH)
    --local                 Run on local machine (bypasses SSH)
    --json                  Output in JSON format (for Jenkins/automation)
    --help                  Show this help message

COMMANDS:
    list                    List all cronjobs with reference numbers
    save [NAME]             Save full cron state
    restore [NAME]          Restore full cron state
    
    stop <REFS>             Stop cronjobs by refs (comma-separated, ranges allowed)
    start <REFS>            Start cronjobs by refs
    
    stop-pattern <PATTERN>  Stop cronjobs matching pattern
    start-pattern <PATTERN> Start cronjobs matching pattern
    
    suspend <PATTERN> [ID]  Stop matching jobs and save tracking info
    resume <ID>             Start only the jobs that were stopped by suspend ID

    list-states             List all saved full states
    list-suspended          List all suspended sessions
    show-state [NAME]       Show contents of a saved state

    demo                    Run an interactive live demo using a temporary Docker container

EOF
    exit 0
}

# Env var overrides
[ -n "$CRON_HOST" ] && SSH_HOST="$CRON_HOST"
[ -n "$CRON_USER" ] && SSH_USER="$CRON_USER"
[ -n "$CRON_PORT" ] && SSH_PORT="$CRON_PORT"
[ -n "$CRON_IDENTITY" ] && SSH_IDENTITY="$CRON_IDENTITY"

# Argument Parsing
while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--host) 
            if [ -z "$2" ]; then echo "Error: --host requires an argument"; exit 1; fi
            SSH_HOST="$2"; shift 2 ;;
        -u|--user) 
            if [ -z "$2" ]; then echo "Error: --user requires an argument"; exit 1; fi
            SSH_USER="$2"; shift 2 ;;
        -p|--port) 
            if [ -z "$2" ]; then echo "Error: --port requires an argument"; exit 1; fi
            SSH_PORT="$2"; shift 2 ;;
        -i|--identity) 
            if [ -z "$2" ]; then echo "Error: --identity requires an argument"; exit 1; fi
            SSH_IDENTITY="$2"; shift 2 ;;
        --docker) 
            if [ -z "$2" ]; then echo "Error: --docker requires an argument"; exit 1; fi
            DOCKER_CONTAINER="$2"; shift 2 ;;
        --local) LOCAL_MODE=1; shift ;;
        --json) JSON_OUTPUT=1; shift ;;
        --help) usage ;;
        -*) echo "Unknown option: $1"; usage ;;
        *) COMMAND="$1"; shift; COMMAND_ARGS="$*"; break ;;
    esac
done

if [ -z "$COMMAND" ]; then usage; fi

# Validation
if [ "$COMMAND" != "demo" ] && [ -z "$SSH_HOST" ] && [ -z "$DOCKER_CONTAINER" ] && [ "$LOCAL_MODE" -eq 0 ]; then
    echo -e "${RED}Error: Must specify --host, --docker, or --local${NC}"
    exit 1
fi

get_state_prefix() {
    if [ -n "$DOCKER_CONTAINER" ]; then
        echo "docker_${DOCKER_CONTAINER}"
    elif [ "$LOCAL_MODE" -eq 1 ]; then
        echo "local_${USER}"
    else
        echo "${SSH_HOST}_${SSH_USER}"
    fi
}

remote_exec() {
    local cmd="$1"
    local input_content="$2"

    if [ -n "$DOCKER_CONTAINER" ]; then
        if [ -n "$input_content" ]; then
            printf "%s\n" "$input_content" | docker exec -i "$DOCKER_CONTAINER" sh -c "$cmd"
        else
            docker exec "$DOCKER_CONTAINER" sh -c "$cmd"
        fi
    elif [ "$LOCAL_MODE" -eq 1 ]; then
        if [ -n "$input_content" ]; then
            printf "%s\n" "$input_content" | sh -c "$cmd"
        else
            sh -c "$cmd"
        fi
    else
        local ssh_opts="-p $SSH_PORT"
        [ -n "$SSH_IDENTITY" ] && ssh_opts="$ssh_opts -i $SSH_IDENTITY"
        
        if [ -n "$input_content" ]; then
            printf "%s\n" "$input_content" | ssh $ssh_opts "${SSH_USER}@${SSH_HOST}" "$cmd"
        else
            ssh $ssh_opts "${SSH_USER}@${SSH_HOST}" "$cmd"
        fi
    fi
}

get_remote_crontab() {
    # crontab -l returns 1 if no crontab, but we want to treat it as empty
    # We filter stderr to avoid noise if no crontab exists
    remote_exec "crontab -l 2>/dev/null || true"
}

set_remote_crontab() {
    local content="$1"
    if [ -z "$content" ]; then
        # If content is empty, remove crontab
        remote_exec "crontab -r || true"
    else
        # Need to be careful with escaping/newlines.
        # Passing via stdin to remote_exec is safest.
        # Ensure trailing newline
        remote_exec "crontab -" "$content"
    fi
}

parse_refs() {
    local input="$1"
    local refs=()
    IFS=',' read -ra parts <<< "$input"
    for part in "${parts[@]}"; do
        if [[ $part =~ ^([0-9]+)-([0-9]+)$ ]]; then
            for ((i=${BASH_REMATCH[1]}; i<=${BASH_REMATCH[2]}; i++)); do
                refs+=("$i")
            done
        else
            refs+=("$part")
        fi
    done
    echo "${refs[@]}"
}

save_state() {
    local name="$1"
    local prefix=$(get_state_prefix)
    local file="${STATE_DIR}/${prefix}_${name}.cron"
    echo -e "${BLUE}Saving state to $file...${NC}"
    get_remote_crontab > "$file"
    echo -e "${GREEN}State saved.${NC}"
}

restore_state() {
    local name="$1"
    local prefix=$(get_state_prefix)
    local file="${STATE_DIR}/${prefix}_${name}.cron"
    if [ ! -f "$file" ]; then echo -e "${RED}Error: State '$name' not found${NC}"; exit 1; fi
    
    echo -e "${BLUE}Restoring state from $file...${NC}"
    local content=$(cat "$file")
    set_remote_crontab "$content"
    echo -e "${GREEN}State restored.${NC}"
}

list_cronjobs() {
    local target="${SSH_USER}@${SSH_HOST}"
    [ -n "$DOCKER_CONTAINER" ] && target="docker:$DOCKER_CONTAINER"
    [ "$LOCAL_MODE" -eq 1 ] && target="local"
    
    if [ "$JSON_OUTPUT" -eq 0 ]; then
        echo -e "${BLUE}Fetching cronjobs from ${target}...${NC}\n"
    fi
    local content=$(get_remote_crontab)
    
    if [ -z "$content" ]; then 
        if [ "$JSON_OUTPUT" -eq 1 ]; then echo "[]"; else echo -e "${YELLOW}No cronjobs found${NC}"; fi
        return
    fi

    local ref=1
    local json_items=()
    
    if [ "$JSON_OUTPUT" -eq 0 ]; then
        echo -e "${GREEN}REF  STATUS    CRONJOB${NC}"
        echo "---  --------  -------"
    fi

    while IFS= read -r line || [ -n "$line" ]; do
        # Escape backslashes first, then double quotes for JSON
        local safe_line="${line//\\/\\\\}"
        safe_line="${safe_line//\"/\\\"}"
        
        if [[ $line =~ ^[[:space:]]*$ ]]; then
            [ "$JSON_OUTPUT" -eq 0 ] && echo "$line"
        elif [[ $line == "$DISABLED_TAG"* ]]; then
            local clean_line="${line#$DISABLED_TAG }"
            local safe_clean_line="${clean_line//\\/\\\\}"
            safe_clean_line="${safe_clean_line//\"/\\\"}"
            if [ "$JSON_OUTPUT" -eq 1 ]; then
                json_items+=("{\"ref\": $ref, \"status\": \"DISABLED\", \"command\": \"$safe_clean_line\"}")
            else
                echo -e "${YELLOW}[$ref]${NC}  ${RED}DISABLED${NC}  $clean_line"
            fi
            ((ref+=1))
        elif [[ $line =~ ^# ]]; then
            [ "$JSON_OUTPUT" -eq 0 ] && echo "$line"
        else
            if [ "$JSON_OUTPUT" -eq 1 ]; then
                json_items+=("{\"ref\": $ref, \"status\": \"ENABLED\", \"command\": \"$safe_line\"}")
            else
                echo -e "${YELLOW}[$ref]${NC}  ${GREEN}ENABLED${NC}   $line"
            fi
            ((ref+=1))
        fi
    done <<< "$content"

    if [ "$JSON_OUTPUT" -eq 1 ]; then
        local json_output="["
        local first=1
        for item in "${json_items[@]}"; do
            if [ $first -eq 1 ]; then
                json_output+="$item"
                first=0
            else
                json_output+=",$item"
            fi
        done
        json_output+="]"
        echo "$json_output"
    fi
}

modify_cron() {
    local mode="$1" # stop, start, pattern-stop, pattern-start, suspend, resume
    local target="$2" # refs or pattern or suspend_id
    local suspend_id="$3"
    
    local content=$(get_remote_crontab)
    local lines=()
    local modified=0
    local ref=1
    local matched_refs=()
    local suspended_lines=()
    local prefix=$(get_state_prefix)

    if [ "$mode" == "resume" ]; then
        local track_file="${STATE_DIR}/${prefix}_${target}.suspend"
        if [ ! -f "$track_file" ]; then echo -e "${RED}Error: Tracking file not found: $track_file${NC}" >&2; exit 1; fi
        # Portable replacement for mapfile
        local target_suspended=()
        while IFS= read -r s_line; do
            target_suspended+=("$s_line")
        done < "$track_file"
    elif [ "$mode" == "stop" ] || [ "$mode" == "start" ]; then
        local target_refs=($(parse_refs "$target"))
    fi

    while IFS= read -r line || [ -n "$line" ]; do
        if [[ $line =~ ^[[:space:]]*$ ]]; then
            lines+=("$line")
            continue
        fi

        # Skip counting regular comments for refs
        if [[ $line =~ ^# ]] && [[ $line != "$DISABLED_TAG"* ]]; then
            lines+=("$line")
            continue
        fi

        local should_change=0
        local new_line="$line"

        case "$mode" in
            stop)
                for r in "${target_refs[@]}"; do if [ "$ref" -eq "$r" ]; then should_change=1; break; fi; done
                if [ $should_change -eq 1 ] && [[ ! $line =~ ^# ]]; then
                    new_line="$DISABLED_TAG $line"; ((modified+=1))
                fi
                ;;
            start)
                for r in "${target_refs[@]}"; do if [ "$ref" -eq "$r" ]; then should_change=1; break; fi; done
                if [ $should_change -eq 1 ] && [[ $line == "$DISABLED_TAG"* ]]; then
                    new_line="${line#$DISABLED_TAG }"; ((modified+=1))
                fi
                ;;
            pattern-stop)
                if [[ ! $line =~ ^# ]] && echo "$line" | grep -qE "$target"; then
                    new_line="$DISABLED_TAG $line"; ((modified+=1))
                elif [[ $line == "$DISABLED_TAG"* ]] && echo "${line#$DISABLED_TAG }" | grep -qE "$target"; then
                    : # matched but already stopped
                fi
                ;;
            pattern-start)
                if [[ $line == "$DISABLED_TAG"* ]] && echo "${line#$DISABLED_TAG }" | grep -qE "$target"; then
                    new_line="${line#$DISABLED_TAG }"; ((modified+=1))
                fi
                ;;
            suspend)
                if [[ ! $line =~ ^# ]] && echo "$line" | grep -qE "$target"; then
                    new_line="$DISABLED_TAG $line"; ((modified+=1))
                    suspended_lines+=("$line")
                fi
                ;;
            resume)
                if [[ $line == "$DISABLED_TAG"* ]]; then
                    local unc="${line#$DISABLED_TAG }"
                    for s in "${target_suspended[@]}"; do
                        if [ "$unc" == "$s" ]; then new_line="$unc"; ((modified+=1)); break; fi
                    done
                fi
                ;;
        esac

        lines+=("$new_line")
        ((ref+=1))
    done <<< "$content"

    if [ $modified -gt 0 ]; then
        local new_content=$(printf "%s\n" "${lines[@]}")
        set_remote_crontab "$new_content"
        if [ "$mode" == "suspend" ]; then
            printf "%s\n" "${suspended_lines[@]}" > "${STATE_DIR}/${prefix}_${suspend_id}.suspend"
        fi
        echo -e "${GREEN}Successfully $mode-ed $modified cronjob(s)${NC}"
    else
        echo -e "${YELLOW}No changes made${NC}"
    fi
}

list_files_with_suffix() {
    local suffix="$1"
    local prefix=$(get_state_prefix)
    # Escape special chars in prefix for sed
    local safe_prefix=$(echo "$prefix" | sed 's/[.[\*^$]/\\&/g')
    local pattern="${STATE_DIR}/${prefix}_*${suffix}"
    
    # We loop through files, but check if pattern matches anything first
    # Or just loop and check existence. Pattern expansion happens in loop.
    local found=0
    for f in $pattern; do 
        if [ -e "$f" ]; then
            # Extract just the name part: remove path, then prefix_, then suffix
            echo "  - $(basename "$f")" | sed "s/^${safe_prefix}_//; s/${suffix}$//"
            found=1
        fi
    done
    if [ $found -eq 0 ]; then
        echo -e "${YELLOW}No saved states found.${NC}"
    fi
}

run_demo() {
    echo -e "${BLUE}=== cronss.sh Live Demo ===${NC}"
    if ! docker info > /dev/null 2>&1; then echo -e "${RED}Error: Docker permissions required${NC}"; exit 1; fi

    # Cleanup any stale demo containers
    echo -e "${YELLOW}Checking for stale demo containers...${NC}"
    docker ps -a --filter "name=cronss-demo-" -q | xargs -r docker rm -f >/dev/null 2>&1

    # Variables must be accessible to trap, so not local
    container="cronss-demo-$(date +%s)"
    image="cronss-demo-img"
    # Use relative path for prettier demo output
    script="./cronss.sh"
    
    tmp=$(mktemp -d)
    cat > "$tmp/Dockerfile" <<EOF
FROM alpine:latest
RUN echo '*/10 * * * * /usr/bin/backup-db.sh' >> /etc/crontabs/root
RUN echo '0 3 * * * /usr/bin/daily-maintenance.sh' >> /etc/crontabs/root
RUN echo '*/5 * * * * /usr/bin/sync-files.sh' >> /etc/crontabs/root
CMD ["crond", "-f"]
EOF
    echo -e "${GREEN}Building temporary demo image...${NC}"
    docker build -t "$image" "$tmp" > /dev/null 2>&1
    echo -e "${GREEN}Starting container '$container'...${NC}"
    docker run -d --rm --name "$container" "$image" > /dev/null
    
    # Define cleanup function
    cleanup() {
        echo ""
        echo -e "${BLUE}=== Demo Cleanup ===${NC}"
        echo -e "Stopping and removing container '$container'..."
        docker stop "$container" > /dev/null 2>&1 || true
        echo -e "Removing temporary files..."
        rm -rf "$tmp"
        echo -e "${GREEN}Cleanup complete.${NC}"
    }
    trap cleanup EXIT

    echo -e "${GREEN}Environment ready!${NC}\n"
    
    read -p "[Step 1] Press Enter to list jobs..."
    echo -e "${BLUE}$ $script --docker $container list${NC}"
    $script --docker "$container" list
    echo ""
    
    read -p "[Step 2] Press Enter to suspend 'backup|sync'..."
    echo -e "${BLUE}$ $script --docker $container suspend 'backup|sync' maint${NC}"
    $script --docker "$container" suspend "backup|sync" maint
    echo -e "\nVerifying changes:"
    echo -e "${BLUE}$ $script --docker $container list${NC}"
    $script --docker "$container" list
    echo ""
    
    read -p "[Step 3] Press Enter to resume..."
    echo -e "${BLUE}$ $script --docker $container resume maint${NC}"
    $script --docker "$container" resume maint
    echo -e "\nFinal state:"
    echo -e "${BLUE}$ $script --docker $container list${NC}"
    $script --docker "$container" list
}

case "$COMMAND" in
    list) list_cronjobs ;;
    stop) modify_cron stop "$COMMAND_ARGS" ;;
    start) modify_cron start "$COMMAND_ARGS" ;;
    stop-pattern) modify_cron pattern-stop "$COMMAND_ARGS" ;;
    start-pattern) modify_cron pattern-start "$COMMAND_ARGS" ;;
    suspend) 
        # shellcheck disable=SC2206
        args=($COMMAND_ARGS)
        modify_cron suspend "${args[0]}" "${args[1]:-"$(date +%Y%m%d_%H%M%S)"}"
        ;;
    resume) modify_cron resume "$COMMAND_ARGS" ;;
    demo) run_demo ;;
    save) 
        name="${COMMAND_ARGS:-$(date +%Y%m%d_%H%M%S)}"
        save_state "$name" ;;
    restore) restore_state "$COMMAND_ARGS" ;;
    list-states) list_files_with_suffix ".cron" ;; 
    list-suspended) list_files_with_suffix ".suspend" ;;
    show-state)
        name="${COMMAND_ARGS}"
        prefix=$(get_state_prefix)
        file="${STATE_DIR}/${prefix}_${name}.cron"
        if [ -f "$file" ]; then
            cat "$file"
        else
            echo -e "${RED}State '$name' not found${NC}"
        fi
        ;;
    *) usage ;;
esac
