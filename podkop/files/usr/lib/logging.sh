COLOR_CYAN="\033[0;36m"
COLOR_GREEN="\033[0;32m"
COLOR_RESET="\033[0m"

log() {
    local message="$1"
    local level="$2"

    if [ "$level" == "" ]; then
        level="info"
    fi

    logger -t "podkop" "[$level] $message"
}

nolog() {
    local message="$1"
    local timestamp
    timestamp=$(date +"%Y-%m-%d %H:%M:%S")

    if [ -t 1 ]; then
        echo -e "${COLOR_CYAN}[$timestamp]${COLOR_RESET} ${COLOR_GREEN}$message${COLOR_RESET}"
    fi
}

echolog() {
    local message="$1"
    local level="$2"

    log "$message" "$level"
    nolog "$message"
}
