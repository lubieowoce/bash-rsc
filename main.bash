#!/usr/bin/env bash
set -eu -o pipefail

function intoJq {
  echo null | jq '$value' --arg value "$1"
}

function get {
  local args=( "$@" )
  echo "$1" | jq "${args[@]:2}" ".$2"
}

function text {
  intoJq "$1"
}

function jsx {
  local component;
  component="$1";
  local args_arr=( "$@" );
  local args_sliced=( "${args_arr[@]:1}" )
  # echo "${args_sliced[@]}" >&2
  local props;

  props="$({
    echo '{'
    local propName; local propVal
    local length=${#args_sliced[@]}
    local last_ix=$((length-1))
    local kv;
    local kvFirst; local nameLength; local sliceLength
    local line
    for ((i=0;i<length;i++)); do
      kv="${args_sliced[$i]}"
      kvFirst=$(echo "$kv" | head)
      propName=$(echo "$kvFirst" | sed -nE 's/^([^=]+)=(.*)/\1/p')
      
      nameLength=${#propName}
      sliceLength=$((nameLength+1))
      propVal="${kv:$sliceLength}"

      if [ "$propName" = "children" ]; then
        propVal=$(echo "$propVal" | jq --slurp 2>/dev/null || intoJq "$propVal")
      else
        propVal=$(echo "$propVal" | jq 2>/dev/null || intoJq "$propVal")
      fi
      line="$(intoJq "$propName"): $propVal"
      if [ $i -ne $last_ix ]; then
        echo "$line,"
      else
        echo "$line"
      fi
    done
    echo '}'
  })"
  echo "{ \"type\": \"$component\", \"props\": $props }" | jq
}

# =============================================================


function isHostElement {
  [[ "$1" =~ ^[a-z]+$ ]]
}

function renderNode {
  local element="$1"
  
  local kind;
  kind="$(echo "$element" | jq -r '. | type')" # string, number, boolean, null, object, array
  # log "renderNode[$kind]: $element" >&2
  case "$kind" in
    string|number|boolean|null)
      echo "$element"
      return 0
      ;;
    array)
      # log "renderNode[array]: $element" >&2
      local length
      length=$(echo "$element" | jq '. | length')
      {
        for ((i=0;i<length;i++)); do
          renderNode "$(get "$element" "[$i]")"
        done
      } | jq -s
      return 0
      ;;
    object)
      renderElement "$element"
      return 0
  esac
}

function renderElement {
  local element="$1"
  local componentType; local componentProps
  componentType="$(get "$element" 'type' -r)"
  componentProps="$(get "$element" 'props')"
  
  if isHostElement "$componentType"; then
    local componentChildren
    componentChildren=$(get "$componentProps" 'children' || echo '[]')
    local childrenRendered
    childrenRendered="$(renderNode "$componentChildren")"
    # log "renderElement[$componentType] children: $componentChildren of '$componentType' rendered: $childrenRendered" >&2
    echo "$element" | jq '.props.children=$newChildren' --argjson newChildren "$childrenRendered"
  else
    local rendered
    rendered="$($componentType "$componentProps")"
    renderNode "$rendered"
  fi
}

# =============================================================

function renderToFlight {
  local renderedToJsx
  renderedToJsx="$(renderNode "$1")"
  echo "0:$(renderNodeToFlight "$renderedToJsx")"
}

function renderNodeToFlight {
  local element="$1"
  local kind;
  kind="$(echo "$element" | jq -r '. | type')" # string, number, boolean, null, object, array
  case "$kind" in
    string|number|boolean|null)
      echo "$element"
      return 0
      ;;
    array)
      # log "renderNode[array]: $element" >&2
      local length
      length=$(echo "$element" | jq '. | length')
      {
        for ((i=0;i<length;i++)); do
          renderNodeToFlight "$(get "$element" "[$i]")"
        done
      } | jq -s
      return 0
      ;;
    object)
      renderElementToFlight "$element"
      return 0
  esac
}

function renderElementToFlight {
  local element="$1"
  local componentType; local componentProps
  componentType="$(get "$element" 'type' -r)"
  componentProps="$(get "$element" 'props')"
  
  if ! isHostElement "$componentType"; then
    echo "renderElementToFlight :: expected all components to be host elements (got: '$componentType')"
    return 1
  fi

  local componentChildren
  # TODO: other props might need rendering too! but that's only for client components
  componentChildren=$(get "$componentProps" 'children' || echo '[]')
  local childrenRendered
  childrenRendered="$(renderNodeToFlight "$componentChildren")"
  # log "renderElement[$componentType] children: $componentChildren of '$componentType' rendered: $childrenRendered" >&2
  
  local serializedProps
  # TODO: proper serialization
  serializedProps="$(echo "$componentProps" | jq '.children=$newChildren' --argjson newChildren "$childrenRendered")"
  echo "$serializedProps" | jq -c '["$", $type, null, $props]' --arg type "$componentType" --argjson props "$serializedProps"
}

# =============================================================

function MyComponent {
  local props="$1"
  jsx div children="$(
    text "Hello from MyComponent, x is $(get "$props" 'x')"
    jsx Child i=0
    get "$props" 'children'
  )"
}

function Child {
  local props="$1"
  jsx span children="$(
    text "Hello from Child number $(get "$props" 'i')"
  )"
}

# tree="$(
#   jsx MyComponent x=1 y=2 children="$({
#     jsx Child i=1
#     jsx Child i=2
#   })"
# )"

# renderToFlight "$tree"

# =============================================================

function testTask {
  log "  testTask :: starting";
  sleep 2;
  log "  testTask :: done sleeping";
  echo "done";
  log "  testTask :: write 1 done";
  echo "even more done";
  # return 1
  
  echo "testTask :: oopsie" >&2
  exit 1

  log "  testTask :: write 2 done";
}


STATE_DIR=$(mktemp -d)
# log "state dir: $STATE_DIR"

LOG_OUTPUT_FILE="$STATE_DIR/stderr"
ln -sf /dev/fd/2 "$LOG_OUTPUT_FILE"
exec 3> "$LOG_OUTPUT_FILE"
# echo "test log to $LOG_OUTPUT_FILE" > "$LOG_OUTPUT_FILE"

# make all logs go to our stderr.
export LOG_OUTPUT="$LOG_OUTPUT_FILE"

function log {
  local output
  output="${LOG_OUTPUT-}"
  # echo "log :: output is $output"
  if [ -n "$output" ]; then
    # echo "log :: writing to file $output"
    # echo "$@" >>"$output"
    echo "$@" >&3
  else
    # echo "log :: writing to stderr"
    echo "$@" >&2
  fi
}

log "test log"


# atomic counter for ids via flock
echo 1 > "$STATE_DIR/currentTaskId"
touch "$STATE_DIR/currentTaskId.lock"
HAS_FLOCK=$(which flock; echo $?)
function createTaskId {
  (
    if [ "$HAS_FLOCK" -eq 0 ]; then
      flock --exclusive "$STATE_DIR/currentTaskId.lock"
    fi
    local currentTaskId;
    read <"$STATE_DIR/currentTaskId" currentTaskId;
    echo $((currentTaskId+1)) > "$STATE_DIR/currentTaskId"
    echo "$currentTaskId"
  )
}

mkdir "$STATE_DIR/tasks"

function createTask {
  local resultDir;
  local statusFile; local resultFile; local errorFile;
  local taskId;
  taskId=$(createTaskId)
  # shellcheck disable=SC2145
  log "createTask :: $@ (task id: $taskId)"
  resultDir="$STATE_DIR/tasks/$taskId"
  mkdir "$resultDir"

  statusFile="$resultDir/status"
  resultFile="$resultDir/result"
  errorFile="$resultDir/error"
  echo 'pending' > "$statusFile"

  local pid
  (
    set +e
    log "subshell :: started"
    # run in a subshell in case it calls `exit`
    if ( "$@" >"$resultFile" 2>"$errorFile" ); then
      log "subshell :: done"
      echo 'fulfilled' > "$statusFile"
      exit 0
    else
      log "subshell :: errored"
      exitCode="$?"
      echo 'rejected' > "$statusFile"
      exit "$exitCode"
    fi
  ) >/dev/null 2>"$LOG_OUTPUT" &
  # ^^^^^^^^^^^^^^^^^^^^^^^^^^
  # important! redirect stdout/stderr so that the shell won't wait for this task (https://unix.stackexchange.com/a/419870)
  pid="$!"

  log "createTask :: got pid $pid"
  echo "{\"taskId\":$taskId,\"pid\":$pid,\"status\":\"$statusFile\",\"result\":\"$resultFile\",\"error\":\"$errorFile\"}"
  log "createTask :: exiting"
  return 0
}

UNAME=$(uname)
function anywait {
  # https://unix.stackexchange.com/a/427133
  if [ "$UNAME" == "Linux" ]; then
      tail --pid=$1 -f /dev/null
  else
      lsof -p $1 +r 1 &>/dev/null
  fi
}


task=$( (createTask testTask 1 2 3) )
log "main :: got $task"
tree "$STATE_DIR" >&2

statusFile=$(get "$task" 'status' -r)
read <"$statusFile" status;
if [ "$status" = 'fulfilled' ]; then
  log "runner :: finished fast ($status)";
  cat "$(get "$task" 'result' -r)"
else
  log "runner :: waiting ($status)";
  anywait "$(get "$task" 'pid')" || true
  read <"$statusFile" status;

  if [ "$status" = 'fulfilled' ]; then
    log "runner :: awaited ($status)";
    cat "$(get "$task" 'result' -r)"
  else
    log "runner :: awaited ($status)";
    cat "$(get "$task" 'error' -r)" >&2
  fi

  log "runner :: finished";
fi

# cat "$LOG_OUTPUT_FILE" >&2