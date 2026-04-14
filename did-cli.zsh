#!/bin/zsh

# Resolve script directory (symlink-safe)
SCRIPT_DIR="${0:A:h}"
cd "$SCRIPT_DIR"

# --- Defaults ---
: ${debug:=0}
: ${DID_URL:=did.crayonconsulting.no}
: ${DID_USER_DISPLAY_NAME:=}
: ${DID_DEFAULT_OUTPUT:=json}
: ${DID_CUSTOMER_MAXLENGTH:=}
: ${DID_PROJECT_MAXLENGTH:=}
: ${DID_PRETTY_FORMAT:=}

# --- Logging ---
debug_log() { [[ "$debug" -eq 1 ]] && print -P "%F{green}DEBUG: $1%f" >&2 }
error_log() { print -P "%F{red}ERROR: $1%f" >&2 }
info_log()  { print -P "%F{cyan}$1%f" >&2 }

# --- .env loading ---
ensure_env_file() {
  if [[ -f .env ]]; then
    return 0
  fi

  if [[ -f .env.sample ]]; then
    if cp .env.sample .env 2>/dev/null; then
      info_log "Created .env from .env.sample."
      return 0
    fi
  fi

  error_log ".env not found. Copy .env.sample to .env and configure it."
  exit 1
}

load_env_file() {
  ensure_env_file
  if ! source .env; then
    error_log "Failed to load .env. Fix invalid shell quoting and try again."
    exit 1
  fi
}

load_env_file

# --- Dependency check ---
check_dep() {
  if ! command -v "$1" &>/dev/null; then
    error_log "Required command '$1' not found."
    exit 1
  fi
}
check_dep curl
check_dep jq
check_dep python3

# --- Shared helpers ---
require_cookie() {
  if [[ -z "$DID_COOKIE" ]]; then
    error_log "DID_COOKIE not set. Configure it with: did-cli config --cookie <value>"
    exit 1
  fi
}

require_flag_value() {
  local flag="$1"

  if (( $# < 2 )) || [[ -z "${2-}" ]] || [[ "${2-}" == --* ]]; then
    error_log "Missing value for $flag"
    exit 1
  fi
}

validate_week() {
  local week="$1"

  if [[ ! "$week" =~ ^[0-9]+$ ]] || (( week < 1 || week > 53 )); then
    error_log "Invalid week '$week'. Use an ISO week number from 1 to 53."
    exit 1
  fi
}

validate_year() {
  local year="$1"

  if [[ ! "$year" =~ ^[0-9]{4}$ ]]; then
    error_log "Invalid year '$year'. Use a four-digit year."
    exit 1
  fi
}

current_tz_offset() {
  python3 - <<'PY'
import time

print(-time.timezone // 60 if time.daylight == 0 else -time.altzone // 60)
PY
}

iso_week_bounds() {
  local week="$1" year="$2"

  DID_WEEK="$week" DID_YEAR="$year" python3 - <<'PY'
import os
import sys
from datetime import datetime, timedelta

week = int(os.environ["DID_WEEK"])
year = int(os.environ["DID_YEAR"])

try:
    start = datetime.strptime(f"{year}-W{week:02d}-1", "%G-W%V-%u")
except ValueError:
    print(f"Invalid ISO week/year combination: week {week}, year {year}", file=sys.stderr)
    raise SystemExit(1)

print(start.strftime("%Y-%m-%d"))
print((start + timedelta(days=6)).strftime("%Y-%m-%d"))
PY
}

update_env_var() {
  local key="$1" value="$2" tmp quoted

  quoted=$(printf '%q' "$value")
  tmp=$(mktemp "${TMPDIR:-/tmp}/did-cli.XXXXXX") || {
    error_log "Unable to create a temporary file while updating .env"
    exit 1
  }

  if [[ -f .env ]]; then
    grep -v "^${key}=" .env > "$tmp" || true
  else
    : > "$tmp"
  fi

  printf '%s=%s\n' "$key" "$quoted" >> "$tmp"
  mv "$tmp" .env
}

# --- GraphQL helper ---
gql_request() {
  local query_file="$1"
  local variables="$2"
  local query
  require_cookie
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
    return 1
  fi

  if [[ "$http_code" != "200" ]]; then
    error_log "HTTP $http_code from did API"
    debug_log "$body_response"
    return 1
  fi

  local gql_errors
  gql_errors=$(echo "$body_response" | jq -r '.errors // empty')
  if [[ -n "$gql_errors" ]]; then
    error_log "GraphQL error: $(echo "$body_response" | jq -r '.errors[0].message')"
    return 1
  fi

  echo "$body_response" | jq '.data'
}

# --- Current user (cached in .env) ---
get_display_name() {
  if [[ -n "$DID_USER_DISPLAY_NAME" ]]; then
    echo "$DID_USER_DISPLAY_NAME"
    return
  fi
  debug_log "Fetching display name (first time)..."
  local name
  if ! name=$(gql_request "status.graphql" '{}' | jq -r '.user.displayName'); then
    return 1
  fi
  if [[ -n "$name" && "$name" != "null" ]]; then
    DID_USER_DISPLAY_NAME="$name"
    update_env_var "DID_USER_DISPLAY_NAME" "$name"
  fi
  echo "$name"
}

# --- Date helpers ---
current_year() { date +%Y }
current_week() { date +%V | sed 's/^0//' }
current_month() { date +%m | sed 's/^0//' }
first_of_month() { date +%Y-%m-01 }
today() { date +%Y-%m-%d }

# Resolve semantic week values (last, next, or numeric)
# Sets both week and year to handle year boundaries
resolve_week() {
  local val="$1"
  case "$val" in
    last)
      python3 -c "
from datetime import datetime, timedelta
d = datetime.now() - timedelta(weeks=1)
print(f'{d.strftime(\"%V\").lstrip(\"0\")} {d.strftime(\"%G\")}')"
      ;;
    next)
      python3 -c "
from datetime import datetime, timedelta
d = datetime.now() + timedelta(weeks=1)
print(f'{d.strftime(\"%V\").lstrip(\"0\")} {d.strftime(\"%G\")}')"
      ;;
    *)
      echo "$val"
      ;;
  esac
}

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

# Format ISO date range as friendly string, e.g. "7-13. april" or "28. mars - 3. april"
friendly_date_range() {
  local start="$1" end="$2"
  python3 -c "
import locale, sys
from datetime import datetime
try:
    locale.setlocale(locale.LC_TIME, 'nb_NO.UTF-8')
except:
    pass
s = datetime.strptime('${start}'[:10], '%Y-%m-%d')
e = datetime.strptime('${end}'[:10], '%Y-%m-%d')
months_nb = {1:'januar',2:'februar',3:'mars',4:'april',5:'mai',6:'juni',
             7:'juli',8:'august',9:'september',10:'oktober',11:'november',12:'desember'}
sm = months_nb[s.month]
em = months_nb[e.month]
if s.month == e.month:
    print(f'{s.day}-{e.day}. {sm}')
else:
    print(f'{s.day}. {sm} - {e.day}. {em}')
"
}

format_hours() {
  local cmax="${DID_CUSTOMER_MAXLENGTH:-0}" pmax="${DID_PROJECT_MAXLENGTH:-0}"

  if [[ -n "$DID_PRETTY_FORMAT" ]]; then
    format_hours_custom "$DID_PRETTY_FORMAT"
    return
  fi

  jq -r --argjson cmax "$cmax" --argjson pmax "$pmax" '
    def pad(n): tostring | if length < n then . + (" " * (n - length)) else . end;
    def trunc(n): tostring | if n > 0 then .[:n] | pad(n) else pad(30) end;
    (map(.duration) | add // 0) as $total |
    "Customer                      Project                       Hours",
    "---                           ---                           ---",
    (.[] | "\(.customer.name | trunc($cmax))\(.project.name | trunc($pmax))\(.duration)"),
    "",
    "Total: \($total * 100 | round / 100) hours"
  '
}

# Day-grouped table for weekly reports
format_hours_by_day() {
  local week_num="$1"
  local cmax="${DID_CUSTOMER_MAXLENGTH:-0}" pmax="${DID_PROJECT_MAXLENGTH:-0}"

  if [[ -n "$DID_PRETTY_FORMAT" ]]; then
    format_hours_by_day_custom "$DID_PRETTY_FORMAT" "$week_num"
    return
  fi

  jq -r --argjson wk "${week_num:-0}" --argjson cmax "$cmax" --argjson pmax "$pmax" '
    def pad(n): tostring | if length < n then . + (" " * (n - length)) else . end;
    def trunc(n): tostring | if n > 0 then .[:n] | pad(n) else pad(30) end;
    def clean_dt: split(".")[0];
    def bold: "\u001b[1m" + . + "\u001b[0m";

    def weekday_full:
      {"1":"Monday","2":"Tuesday","3":"Wednesday","4":"Thursday","5":"Friday","6":"Saturday","0":"Sunday"}[tostring] // "?";
    def month_name:
      {"01":"January","02":"February","03":"March","04":"April","05":"May","06":"June",
       "07":"July","08":"August","09":"September","10":"October","11":"November","12":"December"}[.] // "?";

    def day_num: if . == null then 0 else ltrimstr("0") | tonumber end;

    [.[] | select(.startDateTime != null)]
    | group_by(.startDateTime[:10])
    | sort_by(.[0].startDateTime)
    | . as $days |

    # Week header
    (if ($wk > 0) and ($days | length > 0) then
      ($days | first | .[0].startDateTime[:10]) as $first |
      ($days | last | .[0].startDateTime[:10]) as $last |
      ($first[8:10] | day_num) as $fd |
      ($last[8:10] | day_num) as $ld |
      ($first[5:7] | month_name) as $fm |
      ($last[5:7] | month_name) as $lm |
      (if $fm == $lm then "Week \($wk) (\($fd)-\($ld) \($fm))"
       else "Week \($wk) (\($fd) \($fm) - \($ld) \($lm))" end | bold)
    elif $wk > 0 then ("Week \($wk)" | bold)
    else empty end),
    "",

    # Each day
    ($days[] |
      (map(.duration // 0) | add // 0) as $day_total |
      .[0].startDateTime[:10] as $d |
      ($d[8:10] | day_num) as $dn |
      (.[0].startDateTime | clean_dt | strptime("%Y-%m-%dT%H:%M:%S") | mktime | strftime("%u") | weekday_full) as $wd |

      ("\($wd) \($dn) (\($day_total)h)" | bold),
      (sort_by(.startDateTime) | .[] |
        "  \(.customer.name | trunc($cmax))\(.project.name | trunc($pmax))\(.duration // 0)h"
      ),
      ""
    ),

    # Grand total
    ("Total: \([($days[][] | .duration // 0)] | add // 0 | . * 100 | round / 100)h" | bold)
  '
}

# Custom format: DID_PRETTY_FORMAT is a JSON array of [column_name, display_name, column_length] tuples
# e.g. '[["customer.name","Customer",20],["project.name","Project",30],["duration","Hours",0]]'
# column_name uses dot notation for nested fields (customer.name, project.name, etc.)
format_hours_custom() {
  local fmt="$1"
  jq -r --argjson fmt "$fmt" '
    def getfield(path):
      path | split(".") | . as $parts |
      if ($parts | length) == 1 then .[$parts[0]]
      elif ($parts | length) == 2 then .[$parts[0]][$parts[1]]
      else .[$parts[0]] end;
    def pad(n): tostring | if length < n then . + (" " * (n - length)) else . end;
    def trunc(n): tostring | if n > 0 then .[:n] | pad(n) else . end;
    ($fmt | map(.[1] | trunc(.[2])) | join("")) as $header |
    ($fmt | map("---" | trunc(.[2])) | join("")) as $sep |
    (map(.duration) | add // 0) as $total |
    $header, $sep,
    (.[] as $row | [$fmt[] | . as [$col, $disp, $len] | $row | getfield($col) | trunc($len)] | join("")),
    "",
    "Total: \($total * 100 | round / 100) hours"
  '
}

format_hours_by_day_custom() {
  local fmt="$1" week_num="$2"
  jq -r --argjson fmt "$fmt" --argjson wk "${week_num:-0}" '
    def getfield(path):
      path | split(".") | . as $parts |
      if ($parts | length) == 1 then .[$parts[0]]
      elif ($parts | length) == 2 then .[$parts[0]][$parts[1]]
      else .[$parts[0]] end;
    def pad(n): tostring | if length < n then . + (" " * (n - length)) else . end;
    def trunc(n): tostring | if n > 0 then .[:n] | pad(n) else . end;
    def clean_dt: split(".")[0];
    def bold: "\u001b[1m" + . + "\u001b[0m";
    def weekday_full:
      {"1":"Monday","2":"Tuesday","3":"Wednesday","4":"Thursday","5":"Friday","6":"Saturday","0":"Sunday"}[tostring] // "?";
    def month_name:
      {"01":"January","02":"February","03":"March","04":"April","05":"May","06":"June",
       "07":"July","08":"August","09":"September","10":"October","11":"November","12":"December"}[.] // "?";
    def day_num: if . == null then 0 else ltrimstr("0") | tonumber end;

    [.[] | select(.startDateTime != null)]
    | group_by(.startDateTime[:10])
    | sort_by(.[0].startDateTime)
    | . as $days |

    (if ($wk > 0) and ($days | length > 0) then
      ($days | first | .[0].startDateTime[:10]) as $first |
      ($days | last | .[0].startDateTime[:10]) as $last |
      ($first[8:10] | day_num) as $fd |
      ($last[8:10] | day_num) as $ld |
      ($first[5:7] | month_name) as $fm |
      ($last[5:7] | month_name) as $lm |
      (if $fm == $lm then "Week \($wk) (\($fd)-\($ld) \($fm))"
       else "Week \($wk) (\($fd) \($fm) - \($ld) \($lm))" end | bold)
    elif $wk > 0 then ("Week \($wk)" | bold)
    else empty end),
    "",

    ($days[] |
      (map(.duration // 0) | add // 0) as $day_total |
      .[0].startDateTime[:10] as $d |
      ($d[8:10] | day_num) as $dn |
      (.[0].startDateTime | clean_dt | strptime("%Y-%m-%dT%H:%M:%S") | mktime | strftime("%u") | weekday_full) as $wd |

      ("\($wd) \($dn) (\($day_total)h)" | bold),
      (sort_by(.startDateTime) | .[] as $row |
        "  " + ([$fmt[] | . as [$col, $disp, $len] | $row | getfield($col) | trunc($len)] | join(""))
      ),
      ""
    ),

    ("Total: \([($days[][] | .duration // 0)] | add // 0 | . * 100 | round / 100)h" | bold)
  '
}

# --- Output format ---
# Returns "pretty" or "json" based on flags and config default
resolve_output() {
  local explicit="$1"
  if [[ "$explicit" == "pretty" || "$explicit" == "json" ]]; then
    echo "$explicit"
  elif [[ "$DID_DEFAULT_OUTPUT" == "pretty" ]]; then
    echo "pretty"
  else
    echo "json"
  fi
}

# --- Subcommands ---

cmd_status() {
  local output=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --pretty) output="pretty"; shift ;;
      --json)   output="json"; shift ;;
      *) error_log "Unknown flag: $1"; exit 1 ;;
    esac
  done

  output=$(resolve_output "$output")

  info_log "Fetching status from $DID_URL..."
  local data
  if ! data=$(gql_request "status.graphql" '{}'); then
    exit 1
  fi

  # Also fetch current period
  local week year start_date end_date tz_offset week_bounds
  week=$(current_week)
  year=$(current_year)
  if ! week_bounds=$(iso_week_bounds "$week" "$year"); then
    exit 1
  fi
  start_date="${week_bounds%%$'\n'*}"
  end_date="${week_bounds##*$'\n'}"
  tz_offset=$(current_tz_offset)

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
  if ! ts_data=$(gql_request "timesheet.graphql" "$ts_vars"); then
    exit 1
  fi

  local period
  period=$(echo "$ts_data" | jq --argjson w "$week" '.periods[] | select(.week == $w)')

  if [[ "$output" == "pretty" ]]; then
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

    local friendly_range
    friendly_range=$(friendly_date_range "$period_start" "$period_end")

    print -P "%F{white}Status for %F{cyan}$display_name%f" >&2
    print -P "" >&2
    print -P "%F{white}Current period (week $week, $friendly_range): $status_label" >&2
    print -P "%F{white}  $event_count events, ${total_hours}h%f" >&2
    print -P "" >&2
    print -P "%F{white}Time bank balance: %F{cyan}${balance}h%f" >&2
    print -P "%F{white}Vacation: %F{cyan}${vacation_used}%f/%F{cyan}${vacation_total}%f days used, %F{cyan}${vacation_remaining}%f remaining" >&2
  else
    # Merge period data into JSON output
    echo "$data" | jq --argjson period "${period:-null}" '. + { currentPeriod: $period }'
  fi
}

cmd_report() {
  local customer="" project="" from="" to="" week="" year="" output="" employee=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --customer)  require_flag_value "$@"; customer="$2"; shift 2 ;;
      --project)   require_flag_value "$@"; project="$2"; shift 2 ;;
      --from)      require_flag_value "$@"; from="$2"; shift 2 ;;
      --to)        require_flag_value "$@"; to="$2"; shift 2 ;;
      --week)      require_flag_value "$@"; week="$2"; shift 2 ;;
      --year)      require_flag_value "$@"; year="$2"; shift 2 ;;
      --employee)  require_flag_value "$@"; employee="$2"; shift 2 ;;
      --period)
        require_flag_value "$@"
        case "$2" in
          current) week=$(current_week); year=$(current_year) ;;
          last)    local r=$(resolve_week last); week="${r%% *}"; year="${r##* }" ;;
          next)    local r=$(resolve_week next); week="${r%% *}"; year="${r##* }" ;;
          *) error_log "Unknown period: $2. Use current, last, or next."; exit 1 ;;
        esac
        shift 2 ;;
      --pretty)    output="pretty"; shift ;;
      --json)      output="json"; shift ;;
      *) error_log "Unknown flag: $1"; exit 1 ;;
    esac
  done

  # Resolve semantic week values
  if [[ -n "$week" && ("$week" == "last" || "$week" == "next") ]]; then
    local resolved
    resolved=$(resolve_week "$week")
    week="${resolved%% *}"
    year="${resolved##* }"
  fi

  if [[ -n "$week" ]]; then
    validate_week "$week"
  fi
  if [[ -n "$year" ]]; then
    validate_year "$year"
  fi

  output=$(resolve_output "$output")

  # Default to current user unless --employee is specified
  if [[ -z "$employee" ]]; then
    if ! employee=$(get_display_name); then
      exit 1
    fi
  elif [[ "$employee" == "all" ]]; then
    employee=""
  fi

  # Validate customer/project names against available options
  if [[ -n "$customer" || -n "$project" ]]; then
    debug_log "Validating filter names..."
    local filter_data
    if ! filter_data=$(gql_request "filter-options.graphql" '{}'); then
      exit 1
    fi

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
    # Always pair week with a year to avoid matching across all years
    : ${year:=$(current_year)}
    vars=$(echo "$vars" | jq --argjson w "$week" --argjson y "$year" \
      '. + { query: (.query // {} | . + { week: $w, year: $y }) }')
  elif [[ -n "$year" ]]; then
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
  if ! data=$(gql_request "report.graphql" "$vars"); then
    exit 1
  fi

  if [[ "$output" == "pretty" ]]; then
    # For week queries, fetch period status
    if [[ -n "$week" ]]; then
      local start_date end_date tz_offset week_bounds
      if week_bounds=$(iso_week_bounds "$week" "${year:-$(current_year)}"); then
        start_date="${week_bounds%%$'\n'*}"
        end_date="${week_bounds##*$'\n'}"
        tz_offset=$(current_tz_offset)
        local ts_vars
        ts_vars=$(jq -n \
          --arg sd "$start_date" \
          --arg ed "$end_date" \
          --argjson tz "$tz_offset" \
          '{
            query: { startDate: $sd, endDate: $ed },
            options: { locale: "nb", dateFormat: "DD.MM.YYYY", tzOffset: $tz }
          }')
        local ts_data period is_confirmed
        if ts_data=$(gql_request "timesheet.graphql" "$ts_vars"); then
          period=$(echo "$ts_data" | jq --argjson w "$week" '.periods[] | select(.week == $w)')
          is_confirmed=$(echo "$period" | jq -r '.isConfirmed // false')
          if [[ "$is_confirmed" == "true" ]]; then
            print -P "%F{green}submitted%f" >&2
          else
            print -P "%F{yellow}not submitted%f" >&2
          fi
        fi
      fi
      echo "$data" | jq '.timeEntries' | format_hours_by_day "$week"
    else
      echo "$data" | jq '.timeEntries' | format_hours
    fi
  else
    echo "$data"
  fi
}

cmd_submit() {
  local week="" year="" confirm=0

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --period)
        require_flag_value "$@"
        case "$2" in
          current) week=$(current_week); year=$(current_year) ;;
          last)    local r=$(resolve_week last); week="${r%% *}"; year="${r##* }" ;;
          next)    local r=$(resolve_week next); week="${r%% *}"; year="${r##* }" ;;
          *) error_log "Unknown period: $2. Use current, last, or next."; exit 1 ;;
        esac
        shift 2 ;;
      --week)    require_flag_value "$@"; week="$2"; shift 2 ;;
      --year)    require_flag_value "$@"; year="$2"; shift 2 ;;
      --confirm) confirm=1; shift ;;
      *) error_log "Unknown flag: $1"; exit 1 ;;
    esac
  done

  # Resolve semantic week values
  if [[ -n "$week" && ("$week" == "last" || "$week" == "next") ]]; then
    local resolved
    resolved=$(resolve_week "$week")
    week="${resolved%% *}"
    year="${resolved##* }"
  fi

  : ${week:=$(current_week)}
  : ${year:=$(current_year)}
  validate_week "$week"
  validate_year "$year"

  # Calculate start/end dates for the ISO week
  local start_date end_date week_bounds
  if ! week_bounds=$(iso_week_bounds "$week" "$year"); then
    exit 1
  fi
  start_date="${week_bounds%%$'\n'*}"
  end_date="${week_bounds##*$'\n'}"

  debug_log "Fetching timesheet for week $week/$year ($start_date to $end_date)"

  # Get timezone offset in minutes
  local tz_offset
  tz_offset=$(current_tz_offset)

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
  if ! ts_data=$(gql_request "timesheet.graphql" "$ts_vars"); then
    exit 1
  fi

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
  if ! result=$(gql_request "submit-period.graphql" "$submit_vars"); then
    exit 1
  fi

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
  local url="" cookie="" output="" customer_max="" project_max="" pretty_fmt="" has_setting=0

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --url)              require_flag_value "$@"; url="$2"; shift 2 ;;
      --cookie)           require_flag_value "$@"; cookie="$2"; shift 2 ;;
      --output)           require_flag_value "$@"; output="$2"; shift 2 ;;
      --customer-maxlength) require_flag_value "$@"; customer_max="$2"; shift 2 ;;
      --project-maxlength)  require_flag_value "$@"; project_max="$2"; shift 2 ;;
      --pretty-format)    require_flag_value "$@"; pretty_fmt="$2"; shift 2 ;;
      *) error_log "Unknown flag: $1"; exit 1 ;;
    esac
  done

  if [[ -n "$url" ]]; then
    update_env_var "DID_URL" "$url"
    DID_URL="$url"
    info_log "DID_URL set to $url"
    has_setting=1
  fi

  if [[ -n "$cookie" ]]; then
    update_env_var "DID_COOKIE" "$cookie"
    DID_COOKIE="$cookie"
    info_log "DID_COOKIE updated"
    has_setting=1
  fi

  if [[ -n "$output" ]]; then
    if [[ "$output" != "json" && "$output" != "pretty" ]]; then
      error_log "Invalid output format: $output. Use 'json' or 'pretty'."
      exit 1
    fi
    update_env_var "DID_DEFAULT_OUTPUT" "$output"
    DID_DEFAULT_OUTPUT="$output"
    info_log "DID_DEFAULT_OUTPUT set to $output"
    has_setting=1
  fi

  if [[ -n "$customer_max" ]]; then
    update_env_var "DID_CUSTOMER_MAXLENGTH" "$customer_max"
    DID_CUSTOMER_MAXLENGTH="$customer_max"
    info_log "DID_CUSTOMER_MAXLENGTH set to $customer_max"
    has_setting=1
  fi

  if [[ -n "$project_max" ]]; then
    update_env_var "DID_PROJECT_MAXLENGTH" "$project_max"
    DID_PROJECT_MAXLENGTH="$project_max"
    info_log "DID_PROJECT_MAXLENGTH set to $project_max"
    has_setting=1
  fi

  if [[ -n "$pretty_fmt" ]]; then
    # Validate JSON
    if ! echo "$pretty_fmt" | jq empty 2>/dev/null; then
      error_log "Invalid JSON for --pretty-format"
      exit 1
    fi
    update_env_var "DID_PRETTY_FORMAT" "$pretty_fmt"
    DID_PRETTY_FORMAT="$pretty_fmt"
    info_log "DID_PRETTY_FORMAT updated"
    has_setting=1
  fi

  if [[ "$has_setting" -eq 0 ]]; then
    info_log "Current config:"
    info_log "  DID_URL=$DID_URL"
    info_log "  DID_DEFAULT_OUTPUT=${DID_DEFAULT_OUTPUT:-json}"
    if [[ -n "$DID_COOKIE" ]]; then
      info_log "  DID_COOKIE=$(echo "$DID_COOKIE" | cut -c1-20)..."
    else
      info_log "  DID_COOKIE=<not set>"
    fi
    [[ -n "$DID_CUSTOMER_MAXLENGTH" ]] && info_log "  DID_CUSTOMER_MAXLENGTH=$DID_CUSTOMER_MAXLENGTH"
    [[ -n "$DID_PROJECT_MAXLENGTH" ]] && info_log "  DID_PROJECT_MAXLENGTH=$DID_PROJECT_MAXLENGTH"
    [[ -n "$DID_PRETTY_FORMAT" ]] && info_log "  DID_PRETTY_FORMAT=$DID_PRETTY_FORMAT"
  fi
}

cmd_help() {
  cat >&2 <<'HELP'
did-cli - Command-line interface for did

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
  --period <value>    current, last, or next (week)
  --from <date>       Start date (YYYY-MM-DD or YYYY-MM)
  --to <date>         End date (YYYY-MM-DD or YYYY-MM)
  --week <n>          ISO week number, or: last, next
  --year <number>     Year (default: current)
  --pretty            Human-readable output
  --json              JSON output
                      (default from DID_DEFAULT_OUTPUT in .env)

Submit options:
  --period <value>    current, last, or next
  --week <n>          ISO week number, or: last, next
  --year <number>     Year (default: current)
  --confirm           Skip interactive prompt

Config options:
  --url <hostname>    Set DID instance URL
  --cookie <value>    Set didapp session cookie
  --output <format>   Set default output: json or pretty
  --customer-maxlength <n>  Max display width for customer column
  --project-maxlength <n>   Max display width for project column
  --pretty-format <json>    Column spec: array of [column_name, display_name, width] tuples
                            e.g. '[["customer.name","Customer",15],["project.name","Project",25],["duration","Hours",0]]'

Examples:
  did-cli status --pretty
  did-cli report --customer "Crayon" --from 2026-01 --to 2026-03 --pretty
  did-cli report --week 15 --pretty
  did-cli submit --period current
  did-cli config --cookie "eyJ..."
  did-cli config --output pretty
  did-cli config --project-maxlength 25
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
