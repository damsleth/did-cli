#!/bin/zsh

# Resolve script directory (symlink-safe)
SCRIPT_DIR="${0:A:h}"
cd "$SCRIPT_DIR"

# --- .env loading ---
if [ ! -f .env ]; then
  if [ -f .env.sample ]; then
    if cp .env.sample .env 2>/dev/null; then
      print -P "%F{yellow}Created .env from .env.sample. Set DID_COOKIE then re-run.%f" >&2
      exit 2
    fi
  fi
  print -P "%F{red}ERROR: .env not found. Copy .env.sample to .env and configure it.%f" >&2
  exit 1
fi
source .env

# --- Defaults ---
: ${debug:=0}
: ${DID_URL:=did.crayonconsulting.no}

# --- Logging ---
debug_log() { [[ "$debug" -eq 1 ]] && print -P "%F{green}DEBUG: $1%f" >&2 }
error_log() { print -P "%F{red}ERROR: $1%f" >&2 }
info_log()  { print -P "%F{cyan}$1%f" >&2 }

# --- Dependency check ---
check_dep() {
  if ! command -v "$1" &>/dev/null; then
    error_log "Required command '$1' not found."
    exit 1
  fi
}
check_dep curl
check_dep jq

# --- Cookie validation ---
if [[ -z "$DID_COOKIE" ]]; then
  error_log "DID_COOKIE not set. Get the 'didapp' cookie from your browser and add it to .env"
  exit 1
fi

# --- GraphQL helper ---
gql_request() {
  local query_file="$1"
  local variables="$2"
  local query
  query=$(<"$SCRIPT_DIR/queries/$query_file")

  local body
  body=$(jq -n --arg q "$query" --argjson v "${variables:-null}" '{ query: $q, variables: $v }')

  debug_log "POST https://$DID_URL/graphql ($query_file)"

  local response
  response=$(curl -s -w "\n%{http_code}" \
    -X POST "https://$DID_URL/graphql" \
    -H "Content-Type: application/json" \
    -H "Cookie: didapp=$DID_COOKIE" \
    -d "$body")

  local http_code
  http_code=$(echo "$response" | tail -1)
  local body_response
  body_response=$(echo "$response" | sed '$d')

  if [[ "$http_code" == "401" ]]; then
    error_log "Session expired (401). Update your cookie: did-cli config --cookie <value>"
    exit 1
  fi

  if [[ "$http_code" != "200" ]]; then
    error_log "HTTP $http_code from DID API"
    debug_log "$body_response"
    exit 1
  fi

  local gql_errors
  gql_errors=$(echo "$body_response" | jq -r '.errors // empty')
  if [[ -n "$gql_errors" ]]; then
    error_log "GraphQL error: $(echo "$body_response" | jq -r '.errors[0].message')"
    exit 1
  fi

  echo "$body_response" | jq '.data'
}

# --- Date helpers ---
current_year() { date +%Y }
current_week() { date +%V | sed 's/^0//' }
current_month() { date +%m | sed 's/^0//' }
first_of_month() { date +%Y-%m-01 }
today() { date +%Y-%m-%d }

# Normalize start date: YYYY-MM -> YYYY-MM-01T00:00:00.000Z, YYYY-MM-DD -> +T00:00:00.000Z
normalize_date() {
  local d="$1"
  if [[ "$d" =~ ^[0-9]{4}-[0-9]{2}$ ]]; then
    echo "${d}-01T00:00:00.000Z"
  elif [[ "$d" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
    echo "${d}T00:00:00.000Z"
  else
    echo "$d"
  fi
}

# Normalize end date: YYYY-MM -> last day of month T23:59:59.999Z, YYYY-MM-DD -> +T23:59:59.999Z
normalize_end_date() {
  local d="$1"
  if [[ "$d" =~ ^[0-9]{4}-[0-9]{2}$ ]]; then
    local year="${d:0:4}"
    local month="${d:5:2}"
    local last_day
    last_day=$(date -j -f "%Y-%m-%d" "${year}-${month}-01" +%Y-%m-%d 2>/dev/null | \
      xargs -I{} date -j -v+1m -v-1d -f "%Y-%m-%d" {} +%Y-%m-%d)
    echo "${last_day}T23:59:59.999Z"
  elif [[ "$d" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
    echo "${d}T23:59:59.999Z"
  else
    echo "$d"
  fi
}

# --- Pretty formatting ---
format_hours() {
  jq -r '
    def pad(n): tostring | if length < n then . + (" " * (n - length)) else . end;
    (map(.duration) | add // 0) as $total |
    "Customer            Project             Hours",
    "---                 ---                 ---",
    (.[] | "\(.customer.name | pad(20))\(.project.name | pad(20))\(.duration)"),
    "",
    "Total: \($total) hours"
  '
}

# --- Subcommands ---

cmd_status() {
  local pretty=0

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --pretty) pretty=1; shift ;;
      *) error_log "Unknown flag: $1"; exit 1 ;;
    esac
  done

  info_log "Fetching status from $DID_URL..."
  local data
  data=$(gql_request "status.graphql" '{}')

  # Also fetch current period
  local week year start_date end_date tz_offset
  week=$(current_week)
  year=$(current_year)
  start_date=$(python3 -c "from datetime import datetime; d = datetime.strptime(f'${year}-W${week}-1', '%G-W%V-%u'); print(d.strftime('%Y-%m-%d'))")
  end_date=$(python3 -c "from datetime import datetime, timedelta; d = datetime.strptime(f'${year}-W${week}-1', '%G-W%V-%u') + timedelta(days=6); print(d.strftime('%Y-%m-%d'))")
  tz_offset=$(python3 -c "import time; print(-time.timezone // 60 if time.daylight == 0 else -time.altzone // 60)")

  local ts_vars
  ts_vars=$(jq -n \
    --arg sd "$start_date" \
    --arg ed "$end_date" \
    --argjson tz "$tz_offset" \
    '{
      query: { startDate: $sd, endDate: $ed },
      options: { locale: "nb", dateFormat: "DD.MM.YYYY", tzOffset: $tz }
    }')

  local ts_data
  ts_data=$(gql_request "timesheet.graphql" "$ts_vars")

  local period
  period=$(echo "$ts_data" | jq --argjson w "$week" '.periods[] | select(.week == $w)')

  if [[ "$pretty" -eq 1 ]]; then
    local display_name balance
    display_name=$(echo "$data" | jq -r '.user.displayName // "Unknown"')
    balance=$(echo "$data" | jq -r '.user.timebank.balance // "N/A"')
    local vacation_total vacation_used vacation_remaining
    vacation_total=$(echo "$data" | jq -r '.vacation.total // "N/A"')
    vacation_used=$(echo "$data" | jq -r '.vacation.used // "N/A"')
    vacation_remaining=$(echo "$data" | jq -r '.vacation.remaining // "N/A"')

    # Current period info
    local is_confirmed event_count total_hours period_start period_end
    is_confirmed=$(echo "$period" | jq -r '.isConfirmed // false')
    event_count=$(echo "$period" | jq '.events | length // 0')
    total_hours=$(echo "$period" | jq '[.events[].duration] | add // 0')
    period_start=$(echo "$period" | jq -r '.startDate // "?"')
    period_end=$(echo "$period" | jq -r '.endDate // "?"')
    local status_label
    if [[ "$is_confirmed" == "true" ]]; then
      status_label="%F{green}submitted%f"
    else
      status_label="%F{yellow}not submitted%f"
    fi

    print -P "%F{white}Status for %F{cyan}$display_name%f" >&2
    print -P "" >&2
    print -P "%F{white}Current period (week $week): $status_label" >&2
    print -P "%F{white}  $period_start to $period_end - $event_count events, ${total_hours}h%f" >&2
    print -P "" >&2
    print -P "%F{white}Time bank balance: %F{cyan}${balance}h%f" >&2
    print -P "%F{white}Vacation: %F{cyan}${vacation_used}%f/%F{cyan}${vacation_total}%f days used, %F{cyan}${vacation_remaining}%f remaining" >&2
  else
    # Merge period data into JSON output
    echo "$data" | jq --argjson period "${period:-null}" '. + { currentPeriod: $period }'
  fi
}

cmd_report() {
  local customer="" project="" from="" to="" week="" year="" pretty=0 employee=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --customer)  customer="$2"; shift 2 ;;
      --project)   project="$2"; shift 2 ;;
      --from)      from="$2"; shift 2 ;;
      --to)        to="$2"; shift 2 ;;
      --week)      week="$2"; shift 2 ;;
      --year)      year="$2"; shift 2 ;;
      --employee)  employee="$2"; shift 2 ;;
      --pretty)    pretty=1; shift ;;
      *) error_log "Unknown flag: $1"; exit 1 ;;
    esac
  done

  # Default to current user unless --employee is specified
  if [[ -z "$employee" ]]; then
    debug_log "Scoping to current user..."
    local me
    me=$(gql_request "status.graphql" '{}' | jq -r '.user.displayName')
    employee="$me"
  elif [[ "$employee" == "all" ]]; then
    employee=""
  fi

  # Validate customer/project names against available options
  if [[ -n "$customer" || -n "$project" ]]; then
    debug_log "Validating filter names..."
    local filter_data
    filter_data=$(gql_request "filter-options.graphql" '{}')

    if [[ -n "$customer" ]]; then
      local match
      match=$(echo "$filter_data" | jq -r --arg c "$customer" \
        '.filterOptions.customerNames[] | select(ascii_downcase == ($c | ascii_downcase))')
      if [[ -z "$match" ]]; then
        error_log "Customer '$customer' not found."
        local suggestions
        suggestions=$(echo "$filter_data" | jq -r --arg c "$customer" \
          '[.filterOptions.customerNames[] | select(ascii_downcase | contains(($c | ascii_downcase)))] | join(", ")')
        if [[ -n "$suggestions" ]]; then
          info_log "Did you mean: $suggestions"
        else
          info_log "Available customers:"
          echo "$filter_data" | jq -r '.filterOptions.customerNames[]' | while read -r name; do
            info_log "  $name"
          done
        fi
        exit 1
      fi
      # Use the exact name from the API (correct casing)
      customer="$match"
    fi

    if [[ -n "$project" ]]; then
      local match
      match=$(echo "$filter_data" | jq -r --arg p "$project" \
        '.filterOptions.projectNames[] | select(ascii_downcase == ($p | ascii_downcase))')
      if [[ -z "$match" ]]; then
        error_log "Project '$project' not found."
        local suggestions
        suggestions=$(echo "$filter_data" | jq -r --arg p "$project" \
          '[.filterOptions.projectNames[] | select(ascii_downcase | contains(($p | ascii_downcase)))] | join(", ")')
        if [[ -n "$suggestions" ]]; then
          info_log "Did you mean: $suggestions"
        else
          info_log "Available projects:"
          echo "$filter_data" | jq -r '.filterOptions.projectNames[]' | head -20 | while read -r name; do
            info_log "  $name"
          done
        fi
        exit 1
      fi
      project="$match"
    fi
  fi

  # Build variables JSON
  local vars='{}'

  if [[ -n "$employee" ]]; then
    vars=$(echo "$vars" | jq --arg e "$employee" '. + { query: (.query // {} | . + { employeeNames: [$e] }) }')
  fi
  if [[ -n "$customer" ]]; then
    vars=$(echo "$vars" | jq --arg c "$customer" '. + { query: (.query // {} | . + { customerNames: [$c] }) }')
  fi
  if [[ -n "$project" ]]; then
    vars=$(echo "$vars" | jq --arg p "$project" '. + { query: (.query // {} | . + { projectNames: [$p] }) }')
  fi
  if [[ -n "$from" ]]; then
    local norm_from
    norm_from=$(normalize_date "$from")
    vars=$(echo "$vars" | jq --arg d "$norm_from" '. + { query: (.query // {} | . + { startDateTime: $d }) }')
  fi
  if [[ -n "$to" ]]; then
    local norm_to
    norm_to=$(normalize_end_date "$to")
    vars=$(echo "$vars" | jq --arg d "$norm_to" '. + { query: (.query // {} | . + { endDateTime: $d }) }')
  fi
  if [[ -n "$week" ]]; then
    vars=$(echo "$vars" | jq --argjson w "$week" '. + { query: (.query // {} | . + { week: $w }) }')
  fi
  if [[ -n "$year" ]]; then
    vars=$(echo "$vars" | jq --argjson y "$year" '. + { query: (.query // {} | . + { year: $y }) }')
  fi

  # Default date range if nothing specified: current month
  if [[ -z "$from" && -z "$to" && -z "$week" ]]; then
    local default_from default_to
    default_from="$(first_of_month)T00:00:00.000Z"
    default_to="$(today)T23:59:59.999Z"
    vars=$(echo "$vars" | jq --arg f "$default_from" --arg t "$default_to" \
      '. + { query: (.query // {} | . + { startDateTime: $f, endDateTime: $t }) }')
  fi

  info_log "Querying hours from $DID_URL..."
  local data
  data=$(gql_request "report.graphql" "$vars")

  if [[ "$pretty" -eq 1 ]]; then
    echo "$data" | jq '.timeEntries' | format_hours
  else
    echo "$data"
  fi
}

cmd_submit() {
  local week="" year="" confirm=0

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --period)
        if [[ "$2" == "current" ]]; then
          week=$(current_week)
          year=$(current_year)
        fi
        shift 2 ;;
      --week)    week="$2"; shift 2 ;;
      --year)    year="$2"; shift 2 ;;
      --confirm) confirm=1; shift ;;
      *) error_log "Unknown flag: $1"; exit 1 ;;
    esac
  done

  : ${week:=$(current_week)}
  : ${year:=$(current_year)}

  # Calculate start/end dates for the ISO week
  local start_date end_date
  start_date=$(python3 -c "from datetime import datetime; d = datetime.strptime(f'${year}-W${week}-1', '%G-W%V-%u'); print(d.strftime('%Y-%m-%d'))")
  end_date=$(python3 -c "from datetime import datetime, timedelta; d = datetime.strptime(f'${year}-W${week}-1', '%G-W%V-%u') + timedelta(days=6); print(d.strftime('%Y-%m-%d'))")

  debug_log "Fetching timesheet for week $week/$year ($start_date to $end_date)"

  # Get timezone offset in minutes
  local tz_offset
  tz_offset=$(python3 -c "import time; print(-time.timezone // 60 if time.daylight == 0 else -time.altzone // 60)")

  local ts_vars
  ts_vars=$(jq -n \
    --arg sd "$start_date" \
    --arg ed "$end_date" \
    --argjson tz "$tz_offset" \
    '{
      query: { startDate: $sd, endDate: $ed },
      options: { locale: "nb", dateFormat: "DD.MM.YYYY", tzOffset: $tz }
    }')

  local ts_data
  ts_data=$(gql_request "timesheet.graphql" "$ts_vars")

  # Find the matching period
  local period
  period=$(echo "$ts_data" | jq --argjson w "$week" '.periods[] | select(.week == $w)')

  if [[ -z "$period" || "$period" == "null" ]]; then
    error_log "No period found for week $week/$year"
    exit 1
  fi

  local is_confirmed
  is_confirmed=$(echo "$period" | jq -r '.isConfirmed')
  if [[ "$is_confirmed" == "true" ]]; then
    info_log "Week $week/$year is already submitted."
    exit 0
  fi

  # Show summary
  local event_count total_hours period_id period_start period_end
  event_count=$(echo "$period" | jq '.events | length')
  total_hours=$(echo "$period" | jq '[.events[].duration] | add // 0')
  period_id=$(echo "$period" | jq -r '.id')
  period_start=$(echo "$period" | jq -r '.startDate')
  period_end=$(echo "$period" | jq -r '.endDate')

  info_log "Week $week/$year: $event_count events, ${total_hours}h total"
  info_log "Period: $period_start to $period_end"

  if [[ "$confirm" -eq 0 ]]; then
    print -P -n "%F{yellow}Submit this period? (y/N): %f" >&2
    read -r answer
    if [[ "$answer" != "y" && "$answer" != "Y" ]]; then
      info_log "Aborted."
      exit 0
    fi
  fi

  # Build matched events for submission
  local matched_events
  matched_events=$(echo "$period" | jq '[.events[] | select(.project != null) | {
    id: .id,
    projectId: .project.tag,
    manualMatch: false,
    duration: .duration,
    originalDuration: .originalDuration,
    adjustedMinutes: .adjustedMinutes
  }]')

  local forecasted_hours
  forecasted_hours=$(echo "$period" | jq '.forecastedHours // 0')

  local submit_vars
  submit_vars=$(jq -n \
    --arg id "$period_id" \
    --arg sd "$period_start" \
    --arg ed "$period_end" \
    --argjson events "$matched_events" \
    --argjson fh "$forecasted_hours" \
    --argjson tz "$tz_offset" \
    '{
      period: {
        id: $id,
        startDate: $sd,
        endDate: $ed,
        matchedEvents: $events,
        forecastedHours: $fh
      },
      options: { locale: "nb", dateFormat: "DD.MM.YYYY", tzOffset: $tz }
    }')

  local result
  result=$(gql_request "submit-period.graphql" "$submit_vars")

  local success
  success=$(echo "$result" | jq -r '.result.success')
  if [[ "$success" == "true" ]]; then
    info_log "Week $week/$year submitted successfully!"
    echo "$result"
  else
    local err_msg
    err_msg=$(echo "$result" | jq -r '.result.error.message // "Unknown error"')
    error_log "Submission failed: $err_msg"
    exit 1
  fi
}

cmd_config() {
  local url="" cookie=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --url)    url="$2"; shift 2 ;;
      --cookie) cookie="$2"; shift 2 ;;
      *) error_log "Unknown flag: $1"; exit 1 ;;
    esac
  done

  if [[ -n "$url" ]]; then
    if [[ -f .env ]]; then
      sed -i '' "s|^DID_URL=.*|DID_URL='$url'|" .env
    fi
    info_log "DID_URL set to $url"
  fi

  if [[ -n "$cookie" ]]; then
    if [[ -f .env ]]; then
      # Use single quotes in .env to avoid shell expansion of special chars
      sed -i '' "s|^DID_COOKIE=.*|DID_COOKIE='$cookie'|" .env
    fi
    info_log "DID_COOKIE updated"
  fi

  if [[ -z "$url" && -z "$cookie" ]]; then
    info_log "Current config:"
    info_log "  DID_URL=$DID_URL"
    info_log "  DID_COOKIE=$(echo "$DID_COOKIE" | cut -c1-20)..."
  fi
}

cmd_help() {
  cat >&2 <<'HELP'
did-cli - Command-line interface for DID timesheet

Usage: did-cli <command> [options]

Commands:
  status              Show current period, time bank, and vacation
  report              Query hours with filters
  submit              Submit a timesheet period
  config              View or update configuration
  help                Show this help

Report options:
  --customer <name>   Filter by customer name
  --project <name>    Filter by project name
  --employee <name>   Filter by employee (default: current user)
  --employee all      Show all employees
  --from <date>       Start date (YYYY-MM-DD or YYYY-MM)
  --to <date>         End date (YYYY-MM-DD or YYYY-MM)
  --week <number>     ISO week number
  --year <number>     Year (default: current)
  --pretty            Human-readable output (default: JSON)

Submit options:
  --period current    Submit the current open period
  --week <number>     Specific week to submit
  --year <number>     Year (default: current)
  --confirm           Skip interactive prompt

Config options:
  --url <hostname>    Set DID instance URL
  --cookie <value>    Set didapp session cookie

Examples:
  did-cli status --pretty
  did-cli report --customer "Crayon" --from 2026-01 --to 2026-03 --pretty
  did-cli report --week 15 --pretty
  did-cli submit --period current
  did-cli config --cookie "eyJ..."
HELP
}

# --- Main dispatch ---
case "${1:-help}" in
  status)  shift; cmd_status "$@" ;;
  report)  shift; cmd_report "$@" ;;
  submit)  shift; cmd_submit "$@" ;;
  config)  shift; cmd_config "$@" ;;
  help|--help|-h) cmd_help ;;
  *) error_log "Unknown command: $1. Run 'did-cli help' for usage."; exit 1 ;;
esac
