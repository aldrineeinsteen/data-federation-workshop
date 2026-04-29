#!/usr/bin/env bash

set -Eeuo pipefail

domain_file() {
  local domain_dir="$1"
  printf '%s/domain.yaml\n' "$domain_dir"
}

require_domain() {
  local domain="$1"
  local root_dir="$2"
  local domain_dir="$root_dir/domains/$domain"
  local descriptor

  descriptor="$(domain_file "$domain_dir")"

  case "$domain" in
    ""|*/*|*..*|.*)
      echo "Invalid domain: $domain" >&2
      return 1
      ;;
  esac

  if [ ! -d "$domain_dir" ]; then
    echo "Domain folder not found: $domain_dir" >&2
    return 1
  fi

  if [ ! -f "$descriptor" ]; then
    echo "Domain descriptor not found: $descriptor" >&2
    return 1
  fi
}

print_domain_plan() {
  local domain="$1"
  local root_dir="$2"
  local domain_dir="$root_dir/domains/$domain"

  echo "Domain: $domain"
  echo "Descriptor: $(domain_file "$domain_dir")"

  echo "Schemas that would be applied:"
  find "$domain_dir/schemas" -maxdepth 1 -type f \( -name '*.cql' -o -name '*.sql' \) -print 2>/dev/null | sort | sed 's/^/  - /'

  echo "Jobs that would be applied:"
  find "$domain_dir/jobs" -maxdepth 1 -type f -name '*.py' -print 2>/dev/null | sort | sed 's/^/  - /'
}

