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
WHITE='\033[1;37m'
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
    --docker CONTAINER      Target a running Docker container (or use CRON_DOCKER_CONTAINER env var)
    --local                 Run on local machine (bypasses SSH)
    --json                  Output in JSON format (for Jenkins/automation)
    --help                  Show this help message

COMMANDS:
    list                    List all cronjobs with reference numbers and show active suspended sessions
    save [NAME]             Save full cron state
    restore [NAME]          Restore full cron state
    
    stop <REFS>             Stop cronjobs by refs (comma-separated, ranges allowed)
    start <REFS>            Start cronjobs by refs
    
    stop-pattern <PATTERN>  Stop cronjobs matching pattern
    start-pattern <PATTERN> Start cronjobs matching pattern
    
    stop-all                Stop ALL cronjobs
    start-all               Start ALL cronjobs
    
    suspend <PATTERN> [ID]  Stop matching jobs and save tracking info
    suspend-guarded <PATTERN> <MINUTES> [ID]
                            Suspend jobs with an auto-revert safety net on remote host
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
[ -n "$CRON_DOCKER_CONTAINER" ] && DOCKER_CONTAINER="$CRON_DOCKER_CONTAINER"

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
    else
        # Show active suspended sessions if any
        local prefix=$(get_state_prefix)
        # Escape special chars in prefix for sed
        local safe_prefix=$(echo "$prefix" | sed 's/[.[\*^$]/\\&/g')
        local pattern="${STATE_DIR}/${prefix}_*.suspend"
        
        # Check if any suspend files exist
        if ls $pattern 1> /dev/null 2>&1; then
            echo ""
            echo -e "${BLUE}Active Suspended Sessions:${NC}"
            for f in $pattern; do
                local session_id=$(basename "$f" | sed "s/^${safe_prefix}_//; s/\.suspend$//")
                echo -e "  - ${YELLOW}${session_id}${NC}"
            done
        fi
    fi
}

modify_cron() {
    local mode="$1" # stop, start, pattern-stop, pattern-start, stop-all, start-all, suspend, resume, suspend-guarded
    local target="$2" # refs or pattern or suspend_id
    local suspend_id="$3"
    local guarded_minutes="$4"
    
    local content=$(get_remote_crontab)
    local lines=()
    local modified=0
    local ref=1
    local matched_refs=()
    local suspended_lines=()
    local prefix=$(get_state_prefix)

    # Pre-flight for suspend-guarded
    if [ "$mode" == "suspend-guarded" ]; then
        local remote_backup="/tmp/cronss_safe_${suspend_id}.cron"
        
        if [ "$JSON_OUTPUT" -eq 0 ]; then echo -e "${BLUE}Setting up safety net on remote host...${NC}"; fi
        
        # 1. Save current state to remote
        # We use printf to pipe the content safely
        remote_exec "cat > $remote_backup" "$content"
        
        # 2. Calculate revert time (on remote to ensure sync)
        # Using standard GNU date syntax. Alpine needs 'apk add coreutils' or different syntax.
        # Fallback to simple +Xm if GNU date not detected? 
        # For now, assuming GNU date or compatible.
        local revert_schedule
        revert_schedule=$(remote_exec "date -d '+${guarded_minutes} minutes' +'%M %H * * *' 2>/dev/null || date -v+${guarded_minutes}M +'%M %H * * *' 2>/dev/null")
        
        if [ -z "$revert_schedule" ]; then
            echo -e "${RED}Error: Could not calculate date on remote host. Ensure 'date' supports -d (GNU) or -v (BSD).${NC}"
            exit 1
        fi
        
        local revert_cmd="crontab $remote_backup && rm -f $remote_backup"
        if [ "$JSON_OUTPUT" -eq 0 ]; then echo -e "${YELLOW}Safety net scheduled for: $revert_schedule${NC}"; fi
    fi

    if [ "$mode" == "resume" ]; then
        local track_file="${STATE_DIR}/${prefix}_${target}.suspend"
        if [ ! -f "$track_file" ]; then echo -e "${RED}Error: Tracking file not found: $track_file${NC}" >&2; exit 1; fi
        # Portable replacement for mapfile
        local target_suspended=()
        while IFS= read -r s_line; do
            target_suspended+=("$s_line")
        done < "$track_file"
        
        # Cleanup remote safety net if it exists
        remote_exec "rm -f /tmp/cronss_safe_${target}.cron 2>/dev/null || true"
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
                    new_line="$DISABLED_TAG $line"; ((modified+=1)); matched_refs+=($ref)
                fi
                ;;
            start)
                for r in "${target_refs[@]}"; do if [ "$ref" -eq "$r" ]; then should_change=1; break; fi; done
                if [ $should_change -eq 1 ] && [[ $line == "$DISABLED_TAG"* ]]; then
                    new_line="${line#$DISABLED_TAG }"; ((modified+=1)); matched_refs+=($ref)
                fi
                ;;
            pattern-stop)
                if [[ ! $line =~ ^# ]] && echo "$line" | grep -qE "$target"; then
                    new_line="$DISABLED_TAG $line"; ((modified+=1)); matched_refs+=($ref)
                elif [[ $line == "$DISABLED_TAG"* ]] && echo "${line#$DISABLED_TAG }" | grep -qE "$target"; then
                    : # matched but already stopped
                fi
                ;;
            pattern-start)
                if [[ $line == "$DISABLED_TAG"* ]] && echo "${line#$DISABLED_TAG }" | grep -qE "$target"; then
                    new_line="${line#$DISABLED_TAG }"; ((modified+=1)); matched_refs+=($ref)
                fi
                ;;
            stop-all)
                if [[ ! $line =~ ^# ]]; then
                    new_line="$DISABLED_TAG $line"; ((modified+=1)); matched_refs+=($ref)
                fi
                ;;
            start-all)
                if [[ $line == "$DISABLED_TAG"* ]]; then
                    new_line="${line#$DISABLED_TAG }"; ((modified+=1)); matched_refs+=($ref)
                fi
                ;;
            suspend|suspend-guarded)
                if [[ ! $line =~ ^# ]] && echo "$line" | grep -qE "$target"; then
                    new_line="$DISABLED_TAG $line"; ((modified+=1))
                    suspended_lines+=("$line")
                    matched_refs+=($ref)
                fi
                ;;
            resume)
                if [[ $line == *"#CRONSS_AUTOREVERT:$target"* ]]; then
                    ((modified+=1))
                    continue
                fi

                if [[ $line == "$DISABLED_TAG"* ]]; then
                    local unc="${line#$DISABLED_TAG }"
                    for s in "${target_suspended[@]}"; do
                        if [ "$unc" == "$s" ]; then 
                            new_line="$unc"; ((modified+=1)); matched_refs+=($ref)
                            break
                        fi
                    done
                fi
                ;;
        esac

        lines+=("$new_line")
        ((ref+=1))
    done <<< "$content"

    if [ "$mode" == "suspend-guarded" ] && [ $modified -gt 0 ]; then
         lines+=("$revert_schedule $revert_cmd #CRONSS_AUTOREVERT:$suspend_id")
    fi

    if [ $modified -gt 0 ]; then
        local new_content=$(printf "%s\n" "${lines[@]}")
        set_remote_crontab "$new_content"
        local track_file_out=""
        if [ "$mode" == "suspend" ] || [ "$mode" == "suspend-guarded" ]; then
            track_file_out="${STATE_DIR}/${prefix}_${suspend_id}.suspend"
            printf "%s\n" "${suspended_lines[@]}" > "$track_file_out"
        fi
        
        if [ "$JSON_OUTPUT" -eq 1 ]; then
            local matched_json="["
            local first=1
            for mr in "${matched_refs[@]}"; do
                if [ $first -eq 1 ]; then matched_json+="$mr"; first=0; else matched_json+=",$mr"; fi
            done
            matched_json+="]"
            
            local id_field=""
            if [ "$mode" == "suspend" ] || [ "$mode" == "suspend-guarded" ]; then
                id_field=",\"id\": \"$suspend_id\",\"track_file\": \"$track_file_out\""
            fi
            [ "$mode" == "resume" ] && id_field=",\"id\": \"$target\""
            
            echo "{\"status\": \"success\", \"modified\": $modified, \"action\": \"$mode\", \"matched_refs\": $matched_json${id_field}}"
        else
            local action_past="${mode}ed"
            [[ "$mode" == *e ]] && action_past="${mode}d" # resume -> resumed
            [[ "$mode" == "stop" ]] && action_past="stopped"
            [[ "$mode" == "stop-all" ]] && action_past="stopped all"
            [[ "$mode" == "start-all" ]] && action_past="started all"
            [[ "$mode" == "suspend-guarded" ]] && action_past="suspended (guarded)"
            
            echo -e "${GREEN}Successfully ${action_past} $modified cronjob(s)${NC}"
        fi
    else
        if [ "$JSON_OUTPUT" -eq 1 ]; then
            echo "{\"status\": \"success\", \"modified\": 0, \"action\": \"$mode\", \"matched_refs\": []}"
        else
            echo -e "${YELLOW}No changes made${NC}"
        fi
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
# Install coreutils for advanced date math support
RUN apk add --no-cache coreutils
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

    echo -e "${GREEN}Environment ready!${NC}"
    
    demo_step() {
        local cmd_display="$1"
        local cmd_exec="$2"
        
        # Simulate shell prompt
        echo -ne "${GREEN}user@demo${NC}:${BLUE}~${NC}$ "

        # Typing effect
        local text="${cmd_display}"
        for (( i=0; i<${#text}; i++ )); do
            echo -ne "${WHITE}${text:$i:1}${NC}"
            sleep 0.03
        done

        # Unobstructive notice
        echo -ne "  ${YELLOW}(Press Enter)${NC}"
        read -r _
        
        # Clear the notice by overwriting with spaces then moving back
        # \033[1A moves cursor up one line because 'read' (user pressing Enter) created a newline
        # \r goes to start, we reprint the prompt part
        echo -ne "\033[1A\r${GREEN}user@demo${NC}:${BLUE}~${NC}$ ${WHITE}${cmd_display}${NC}               \n"
        
        eval "$cmd_exec"
    }

    echo ""
    demo_step "$script --docker $container list" "$script --docker $container list"
    
    echo ""
    echo -e "${YELLOW}[Scenario] Maintenance window starting. Suspending 'backup' and 'sync' jobs.${NC}"
    demo_step "$script --docker $container suspend 'backup|sync' maint" "$script --docker $container suspend 'backup|sync' maint"
    
    echo ""
    echo -e "${YELLOW}[Verification] Checking that jobs are disabled...${NC}"
    demo_step "$script --docker $container list" "$script --docker $container list"
    
    echo ""
    echo -e "${YELLOW}[Scenario] Maintenance complete. Resuming jobs.${NC}"
    demo_step "$script --docker $container resume maint" "$script --docker $container resume maint"

    echo ""
    echo -e "${YELLOW}[Scenario] Safety Net Test: Suspend with auto-revert in 60 minutes.${NC}"
    echo -e "${YELLOW}           (Notice the new temporary job added at the bottom)${NC}"
    demo_step "$script --docker $container suspend-guarded 'backup' 60 safety-test" "$script --docker $container suspend-guarded 'backup' 60 safety-test"
    
    echo ""
    echo -e "${YELLOW}[Verification] Check crontab for the auto-revert job.${NC}"
    demo_step "$script --docker $container list" "$script --docker $container list"

    echo ""
    echo -e "${YELLOW}[Cleanup] Resuming normally removes the safety net.${NC}"
    demo_step "$script --docker $container resume safety-test" "$script --docker $container resume safety-test"

    echo ""
    echo -e "${YELLOW}[Scenario] Emergency! Stopping ALL cronjobs.${NC}"
    demo_step "$script --docker $container stop-all" "$script --docker $container stop-all"
    
    echo ""
    echo -e "${YELLOW}[Verification] Everything should be disabled.${NC}"
    demo_step "$script --docker $container list" "$script --docker $container list"

    echo ""
    echo -e "${YELLOW}[Scenario] Emergency over. Restarting ALL cronjobs.${NC}"
    demo_step "$script --docker $container start-all" "$script --docker $container start-all"

    echo ""
    echo -e "${YELLOW}[Final Check]${NC}"
    demo_step "$script --docker $container list" "$script --docker $container list"
}

case "$COMMAND" in
    list) list_cronjobs ;;
    stop) modify_cron stop "$COMMAND_ARGS" ;;
    start) modify_cron start "$COMMAND_ARGS" ;;
    stop-pattern) modify_cron pattern-stop "$COMMAND_ARGS" ;;
    start-pattern) modify_cron pattern-start "$COMMAND_ARGS" ;;
    stop-all) modify_cron stop-all "" ;;
    start-all) modify_cron start-all "" ;;
    suspend) 
        # shellcheck disable=SC2206
        args=($COMMAND_ARGS)
        modify_cron suspend "${args[0]}" "${args[1]:-"$(date +%Y%m%d_%H%M%S)"}"
        ;;
    suspend-guarded)
        # shellcheck disable=SC2206
        args=($COMMAND_ARGS)
        if [ -z "${args[1]}" ]; then echo "Error: Minutes argument required for suspend-guarded"; exit 1; fi
        modify_cron suspend-guarded "${args[0]}" "${args[2]:-"$(date +%Y%m%d_%H%M%S)"}" "${args[1]}"
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
