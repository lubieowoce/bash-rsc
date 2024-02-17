#!/usr/bin/env bash
set -eu -o pipefail

function intoJq {
  echo null | jq '$value' --arg value "$1"
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
    local propName
    local propVal
    local length=${#args_sliced[@]}
    local last_ix=$((length-1))
    local kv
    local line
    for ((i=0;i<length;i++)); do
      kv="${args_sliced[$i]}"
      kv=$(echo "$kv" | tr '\n' ' ')
      propName=$(echo "$kv" | sed -nE 's/^([^=]+)=(.*)/\1/p')
      propVal=$(echo "$kv" | sed -nE 's/^([^=]+)=(.*)/\2/p')
      if [ "$propName" = "children" ]; then
        propVal=$(echo "$propVal" | jq --slurp || intoJq "$propVal")
      else
        propVal=$(echo "$propVal" | jq || intoJq "$propVal")
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

jsx MyComponent x=1 y=2 children="$({
  jsx Child i=1
  jsx Child i=2
})"
