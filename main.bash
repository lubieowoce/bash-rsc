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

function isComponent {
  [[ "$1" =~ ^[A-Z] ]]
}

function getJsonType {
  echo "$1" | jq -r '. | type'
}

function isJsxElement {
  local type
  type="$(getJsonType "$1")"
  [ "$type" = "object" ]
}

function renderNode {
  local element="$1"
  
  local kind;
  kind="$(getJsonType "$element")" # string, number, boolean, null, object, array
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
        declare -a tasks
        local task
        declare -a syncResults
        local syncResult
        local childElement
        local status
        for ((i=0;i<length;i++)); do
          childElement="$(get "$element" "[$i]")"
          if isJsxElement "$childElement"; then
            task="$(createTask renderNode "$childElement")"
            tasks[$i]="$task"
            # TODO: check for fast finish?
            syncResults[$i]=''
          else
            syncResult="$(renderNode "$childElement")"
            tasks[$i]=''
            syncResults[$i]="$syncResult"
          fi
        done
        for ((i=0;i<length;i++)); do
          task="${tasks[$i]}"
          if [ -z "$task" ]; then
            echo "${syncResults[$i]}"
          else
            # log "renderNode :: awaiting task $task"
            awaitTask "$task" >/dev/null
            status="$(getTaskStatus "$task")"
            if [ "$status" = 'fulfilled' ]; then
              cat "$(get "$task" 'result' -r)"
              # log "renderNode :: awaited ($status)";
              # local result
              # result="$(cat "$(get "$task" 'result' -r)")"
              # log "renderNode :: task result: $result"
              # echo "$result"
            else
              # log "renderNode :: awaited ($status)";
              local errorFile
              errorFile="$(get "$task" 'error' -r)"
              echo null | jq '{ "type": "error", "props": { "message": $message } }' --arg message "$(cat "$errorFile")"
            fi
          fi
        done
      } | jq -s
      return 0
      ;;
    object)
      renderElement "$element"
      return 0
  esac
}

function getHexId {
  printf '%x' "$1"
}

function emitChunk {
  local id="$1"
  local contents="$2"
  echo "$(getHexId "$id"):$contents" >&4
}

function renderElement {
  local element="$1"
  local componentType; local componentProps
  componentType="$(get "$element" 'type' -r)"
  componentProps="$(get "$element" 'props')"
  
  if isComponent "$componentType"; then
    local rendered
    # local task
    # task="$(createTask "$componentType" "$componentProps")"
    rendered="$("$componentType" "$componentProps")"
    renderNode "$rendered"
    return "$?"
  fi

  local componentChildren
  componentChildren=$(get "$componentProps" 'children' || echo 'null')
  if [ "$componentType" = "react.suspense" ]; then
    local task
    task="$(createTask renderNode "$componentChildren")"
    log "renderElement :: suspense task $task"
    sleep 0.1
    local status
    status="$(getTaskStatus "$task")"
    case "$status" in
      rejected)
        log "NOT IMPLEMENTED: suspense can't handle rejections yet"
        echo "null"
        return 0
      ;;
      fulfilled)
        local resultFile
        resultFile="$(get "$task" 'result')"
        cat "$resultFile"
      ;;
      pending)
        # TODO: wrap this up in createChunkSync?
        local symbolId
        symbolId=$(createTaskId "chunks")
        emitChunk "$symbolId" '"$''Sreact.suspense"'

        local chunk
        chunk="$(createChunk emitChunkWhenTaskComplete "$task")"
        local rowId
        rowId=$(get "$chunk" 'taskId')
        
        local suspenseRef='$'"$symbolId"
        local contentRef='$''L'"$rowId"

        # TODO: this should work for any JSX prop
        local fallbackProp
        fallbackProp="$(get "$componentProps" 'fallback' || echo 'null')"
        fallbackRendered="$(renderNode "$fallbackProp")"

        local fallback='["$","'"$suspenseRef"'",null,{"fallback":'"$fallbackRendered"',"children":"'"$contentRef"'"}]'
        # fallback=$(get "$fallback" '')
        # log "suspense fallback $fallback"
        echo "$fallback"
      ;;
    esac
    return 0
  fi
  if isHostElement "$componentType"; then
    local childrenRendered
    childrenRendered="$(renderNode "$componentChildren")"
    if [ -z "$childrenRendered" ]; then
      childrenRendered="null"
    fi
    # log "renderElement[$componentType] children: $componentChildren of '$componentType' rendered: $childrenRendered" >&2
    # echo "$element" | jq '.props.children=$newChildren' --argjson newChildren "$childrenRendered"
    local serializedProps
    # TODO: proper serialization
    serializedProps="$(echo "$componentProps" | jq '.children=$newChildren' --argjson newChildren "$childrenRendered")"
    echo "$serializedProps" | jq -c '["$", $type, null, $props]' --arg type "$componentType" --argjson props "$serializedProps"
  fi
}

function emitChunkWhenTaskComplete {
  local chunkId="$CHUNK_ID"
  awaitTask "$task" >/dev/null
  local resultFile
  resultFile="$(get "$task" 'result' -r)"
  local result
  result="$(cat "$resultFile")"
  log "suspense :: writing result chunk $result"
  emitChunk "$chunkId" "$result"
}

# =============================================================

function renderToFlight {
  local chunk
  chunk="$(createChunk renderNode "$1")"

  awaitTask "$chunk" >/dev/null
  local contents
  contents="$(cat "$(get "$chunk" 'result' -r)")"
  emitChunk "$(get "$chunk" 'taskId')" "$contents"

  # TODO: yuck
  local numPendingChunks
  while true; do
    numPendingChunks="$(getPending "chunks")"
    log "renderToFlight :: pending chunks $numPendingChunks"
    if [ "$numPendingChunks" -eq 0 ]; then
      break
    else
      sleep 0.1
    fi
  done

}

# =============================================================


STATE_DIR=$(mktemp -d)
# log "state dir: $STATE_DIR"

LOG_OUTPUT_FILE="$STATE_DIR/stderr"
ln -sf /dev/fd/2 "$LOG_OUTPUT_FILE"
exec 3> "$LOG_OUTPUT_FILE"
# echo "test log to $LOG_OUTPUT_FILE" > "$LOG_OUTPUT_FILE"

# make all logs go to our stderr.
export LOG_OUTPUT="$LOG_OUTPUT_FILE"

STREAM_OUTPUT_FILE="$STATE_DIR/stream"
ln -sf /dev/fd/1 "$STREAM_OUTPUT_FILE"
exec 4> "$STREAM_OUTPUT_FILE"
export STREAM_OUTPUT="$STREAM_OUTPUT_FILE"

function log {
  if [ "${NO_INTERNAL_LOGS-0}" = "1" ]; then
    return 0
  fi
  local output="${LOG_OUTPUT-}"
  local taskId="${TASK_ID-}"
  local prefix=""
  if [ -n "$taskId" ]; then
    prefix="[$taskId]"
  fi
  if [ -n "$output" ]; then
    echo "$prefix" "$@" >&3
  else
    echo "$prefix" "$@" >&2
  fi
}

function logUser {
  local output="${LOG_OUTPUT-}"
  local taskId="${TASK_ID-}"
  local prefix=""
  if [ -n "$taskId" ]; then
    prefix="[$taskId]"
  fi
  if [ -n "$output" ]; then
    echo -e "\033[90m$prefix" "$@" "\033[0m" >&3
  else
    echo "$prefix" "$@" >&2
  fi
}



function ensureAtomicVar {
  local baseDir="$1"
  local varName="$2"
  local dir="$STATE_DIR/$baseDir"
  mkdir -p "$dir"
  if ! [ -f "$dir/$varName" ]; then
    echo 0 > "$dir/$varName"
    touch "$dir/$varName.lock"
  fi
}

function lockAtomicVar {
  local baseDir="$1"
  local varName="$2"
  local dir="$STATE_DIR/$baseDir"

   if [ "$HAS_FLOCK" -eq 0 ]; then
    flock --exclusive "$dir/$varName.lock"
  fi
}

function incrPending {
  local baseDir="$1"
  local dir="$STATE_DIR/$baseDir"
  local varName="pending"
  ensureAtomicVar "$baseDir" "$varName"
  (
    lockAtomicVar "$baseDir" "$varName"
    local currentValue;
    read <"$dir/$varName" currentValue;
    log "incrPending[$baseDir] from $currentValue"
    echo $((currentValue+1)) > "$dir/$varName"
  )
}

function decrPending {
  local baseDir="$1"
  local dir="$STATE_DIR/$baseDir"
  local varName="pending"
  ensureAtomicVar "$baseDir" "$varName"
  (
    lockAtomicVar "$baseDir" "$varName"
    local currentValue;
    read <"$dir/$varName" currentValue;
    log "decrPending[$baseDir] from $currentValue"
    echo $((currentValue-1)) > "$dir/$varName"
  )
}

function getPending {
  local baseDir="$1"
  local dir="$STATE_DIR/$baseDir"
  local varName="pending"
  ensureAtomicVar "$baseDir" "$varName"
  (
    lockAtomicVar "$baseDir" "$varName"
    local currentValue;
    read <"$dir/$varName" currentValue;
    echo "$currentValue"
  )
}


# atomic counter for ids via flock
HAS_FLOCK=$(which flock; echo $?)
function createTaskId {
  local baseDir="$1"
  local dir="$STATE_DIR/$baseDir"
  local varName="currentId"
  ensureAtomicVar "$baseDir" "$varName"
  (
    lockAtomicVar "$baseDir" "$varName"
    local currentValue;
    read <"$dir/$varName" currentValue;
    echo $((currentValue+1)) > "$dir/$varName"
    echo "$currentValue"
  )
}

realJq="$(which jq)"
function jq {
  "$realJq" -c "$@"

  # local input
  # input="$(cat /dev/fd/0)"

  # local exitCode
  # echo "$input" | "$realJq" "$@"
  # exitCode="$?"
  # if [ $exitCode -ne 0 ]; then
  #   log "jq failed for args: '$@' and input '$input'"
  # fi
  # return "$exitCode"
}
export -f jq

function createChunk {
  createTaskBase "chunks" "CHUNK_ID" "$@"
}

function createTask {
  createTaskBase "tasks" "TASK_ID" "$@"
}

function createTaskBase {
  local baseDirName="$1" 
  local ctxEnvVarName="$2" 
  local args=( "$@" )
  args=( "${args[@]:2}" )

  local resultDir;
  local statusFile; local resultFile; local errorFile;

  local baseDir="$STATE_DIR/$baseDirName"
  local parentTaskId="${!ctxEnvVarName-}"
  
  local taskId;
  taskId=$(createTaskId "$baseDirName")

  # shellcheck disable=SC2145
  log "createTask[$baseDirName][$taskId] :: ${args[@]}"
  
  resultDir="$baseDir/$taskId"
  mkdir "$resultDir"
  if [ -n "$parentTaskId" ]; then
    local parentResultDir="$baseDir/$parentTaskId"
    ln -s "$parentResultDir" "$resultDir/parent"
    mkdir -p "$parentResultDir/children"
    ln -s "$resultDir" "$parentResultDir/children/$taskId"
  fi
  statusFile="$resultDir/status"
  resultFile="$resultDir/result"
  errorFile="$resultDir/error"

  echo 'pending' > "$statusFile"
  incrPending "$baseDirName"

  local pid
  (
    set +e
    export "$ctxEnvVarName"="$taskId"
    # log "subshell :: started"
    # run in a subshell in case it calls `exit`
    if ( "${args[@]}" >"$resultFile" 2>"$errorFile" ); then
      log "createTask[$baseDirName][$taskId] :: fulfilled"
      echo 'fulfilled' > "$statusFile"
      decrPending "$baseDirName"
      exit 0
    else
      exitCode="$?"
      log "createTask[$baseDirName][$taskId] :: rejected"
      echo 'rejected' > "$statusFile"
      decrPending "$baseDirName"
      exit "$exitCode"
    fi
  ) >/dev/null 2>"$LOG_OUTPUT" &
  # ^^^^^^^^^^^^^^^^^^^^^^^^^^
  # important! redirect stdout/stderr so that the shell won't wait for this task (https://unix.stackexchange.com/a/419870)
  pid="$!"

  # log "createTask :: got pid $pid"
  echo "{\"taskId\":$taskId,\"pid\":$pid,\"status\":\"$statusFile\",\"result\":\"$resultFile\",\"error\":\"$errorFile\"}"
  # log "createTask :: exiting"
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

function getTaskStatus {
  local task="$1"
  local statusFile
  statusFile=$(get "$task" 'status' -r)
  local taskId
  taskId=$(get "$task" 'taskId' -r)
  read <"$statusFile" status || { log "getTaskStatus[$taskId] :: failed to read status for task '$task'"; return 1; }
  echo "$status"
}

function awaitTask {
  local task="$1"
  anywait "$(get "$task" 'pid')" || true
  local status;
  status="$(getTaskStatus "$task")"

  if [ "$status" = 'fulfilled' ]; then
    # log "runner :: awaited ($status)";
    # cat "$(get "$task" 'result' -r)"
    echo "$status"
    return 0
  else
    # log "runner :: awaited ($status)";
    # cat "$(get "$task" 'error' -r)" >&2
    echo "$status"
    return 1
  fi
}

function tryResolveTask {
  local task="$1"
  local status
  status="$(getTaskStatus "$task")"
  
  if [ "$status" = 'fulfilled' ]; then
    log "runner :: finished fast ($status)";
    cat "$(get "$task" 'result' -r)"
  else
    log "runner :: waiting ($status)";
    awaitTask "$task" >/dev/null
    status="$(getTaskStatus "$task")"

    if [ "$status" = 'fulfilled' ]; then
      log "runner :: awaited ($status)";
      cat "$(get "$task" 'result' -r)"
    else
      log "runner :: awaited ($status)";
      cat "$(get "$task" 'error' -r)" >&2
    fi

    log "runner :: finished";
  fi
}

# task=$( (createTask testTask 1 2 3) )
# log "main :: got $task"
# tryResolveTask "$task"


function MyComponent {
  local props="$1"
  logUser "hello from MyComponent"
  jsx div children="$(
    text "Hello from MyComponent, x is $(get "$props" 'x')"
    jsx react.suspense fallback="$(text "Loading...")" children="$(
      jsx Child i=0
      get "$props" 'children'
    )"
  )"
}

function Child {
  local props="$1"
  logUser "Child $(get "$props" 'i') :: sleeping for 2s"
  sleep 2
  logUser "Child $(get "$props" 'i') :: woken up"
  jsx span children="$(
    text "Hello from Child number $(get "$props" 'i')"
  )"
}

tree="$(
  jsx MyComponent x=1 y=2 children="$({
    jsx Child i=1
    jsx Child i=2
  })"
)"

renderToFlight "$tree"
















if [ "${NO_INTERNAL_LOGS-0}" != "1" ]; then 
  echo "$STATE_DIR" >&2
  ( cd "$STATE_DIR"; tree "$STATE_DIR" ) >&2
fi
