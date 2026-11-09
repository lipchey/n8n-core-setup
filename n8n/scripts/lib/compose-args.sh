#!/bin/bash
_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_base="${_script_dir}/../../docker-compose.yml"
_args=(-f "$_base")

printf '%s ' "${_args[@]}"
