#!/usr/bin/env sh
# shellcheck disable=SC2034
dns_katapult_info='Katapult.io
Site: katapult.io/products/dns-management/
Docs: docs.katapult.io/docs/dev/welcome
Options:
 KATAPULT_ORGANIZATION_ID Organization ID from https://my.katapult.io/
 KATAPULT_ACCESS_TOKEN API token secret from https://my.katapult.io/
Author: @stanno'

KATAPULT_URL="https://api.katapult.io/core/v1/"

########  Public functions #####################

# Please Read this guide first: https://github.com/acmesh-official/acme.sh/wiki/DNS-API-Dev-Guide

dns_katapult_add() {
  fulldomain=$1
  txtvalue=$2

  KATAPULT_ORGANIZATION_ID="${KATAPULT_ORGANIZATION_ID:-$(_readaccountconf_mutable KATAPULT_ORGANIZATION_ID)}"
  KATAPULT_ACCESS_TOKEN="${KATAPULT_ACCESS_TOKEN:-$(_readaccountconf_mutable KATAPULT_ACCESS_TOKEN)}"

  if [ -z "$KATAPULT_ORGANIZATION_ID" ] || [ -z "$KATAPULT_ACCESS_TOKEN" ]; then
    _err "Please specify your Katapult Organization ID and Token and try again."
    return 1
  else
    _saveaccountconf_mutable KATAPULT_ORGANIZATION_ID "$KATAPULT_ORGANIZATION_ID"
    _saveaccountconf_mutable KATAPULT_ACCESS_TOKEN "$KATAPULT_ACCESS_TOKEN"
  fi

  _info "Using Katapult"
  _debug fulldomain "$fulldomain"
  _debug txtvalue "$txtvalue"

  if ! _get_root "$fulldomain"; then
    _err "invalid domain"
    return 1
  fi

  _debug _domain_id "$_domain_id"
  _debug _sub_domain "$_sub_domain"
  _debug _domain "$_domain"

  if _get_record "$fulldomain" "$txtvalue"; then
    _info "record $_record_id already exists"
    return 0
  fi

  body="{\"dns_zone\":{\"id\":\"$_domain_id\"},\
\"properties\":{\"name\":\"$_sub_domain\",\"type\":\"TXT\",\"ttl\":60,\
\"content\":{\"TXT\":{\"content\":\"$txtvalue\"}}}}"

  if _katapult_rest POST "dns_zones/dns_zone/records" "$body"; then
    _info "validation value added"
    return 0
  else
    _err "error adding validation value ($_code)"
    return 1
  fi

}

#Usage: fulldomain txtvalue
#Remove the txt record after validation.
dns_katapult_rm() {
  fulldomain=$1
  txtvalue=$2
  _info "Using Katapult"
  _debug fulldomain "$fulldomain"
  _debug txtvalue "$txtvalue"

  KATAPULT_ORGANIZATION_ID="${KATAPULT_ORGANIZATION_ID:-$(_readaccountconf_mutable KATAPULT_ORGANIZATION_ID)}"
  KATAPULT_ACCESS_TOKEN="${KATAPULT_ACCESS_TOKEN:-$(_readaccountconf_mutable KATAPULT_ACCESS_TOKEN)}"

  if ! _get_root "$fulldomain"; then
    _err "invalid domain"
    return 1
  fi

  _debug _domain_id "$_domain_id"
  _debug _sub_domain "$_sub_domain"
  _debug _domain "$_domain"

  if ! _get_record "$fulldomain" "$txtvalue"; then
    _err "record $fulldomain $txtvalue doesn’t exist"
    return 1
  fi

  _debug _record_id "$_record_id"

  if [ "$_record_id" ]; then

    body="{\"dns_record\":{\"id\":\"$_record_id\"}}"

    if _katapult_rest DELETE "dns_records/dns_record" "$body"; then
      _info "validation value removed"
      return 0
    else
      _err "error removing validation value"
      return 1
    fi

  fi
  return 1
}

####################  Private functions below ##################################

_get_root() {
  domain=$1
  i=1
  p=1

  if ! _katapult_rest GET "organizations/organization/dns_zones?organization[id]=$KATAPULT_ORGANIZATION_ID"; then
    return 1
  fi

  while true; do
    h=$(printf "%s" "$domain" | cut -d . -f "$i"-100)
    _debug2 "Checking domain: $h"
    if [ -z "$h" ]; then
      #not valid
      _err "Invalid domain"
      return 1
    fi

    if _contains "$response" "\"name\":\"$h\"" >/dev/null; then
      _domain_id=$(echo "$response" | _egrep_o "\"[^\"]*\",\"name\":\"$h\"" | cut -d , -f 1 | tr -d \")
      if [ "$_domain_id" ]; then
        if [ "$i" = 1 ]; then
          #create the record at the domain apex (@) if only the domain name was provided as --domain-alias
          _sub_domain="@"
        else
          _sub_domain=$(echo "$domain" | cut -d . -f 1-"$p")
        fi
        _domain=$h
        return 0
      fi
      return 1
    fi
    p=$i
    i=$(_math "$i" + 1)
  done

  return 1
}

_get_record() {
  fullname="$1"
  content="$2"
  _debug2 "Searching for $fullname record $content"

  if ! _katapult_rest GET "dns_zones/dns_zone/records?dns_zone[id]=$_domain_id"; then
    return 1
  fi

  if _contains "$response" "\"full_name\":\"$fullname\"" >/dev/null; then
    if [ -z "$content" ]; then
      _record_id=$(echo "$response" | _egrep_o "\"id\":\"[^\"]*\"[^{}]*\"full_name\":\"$fullname\"[^{}]*\"type\":\"TXT\"" | head -1 | cut -d , -f 1 | cut -d : -f 2 | tr -d \")
    else
      _record_id=$(echo "$response" | _egrep_o "\"id\":\"[^\"]*\"[^{}]*\"full_name\":\"$fullname\"[^{}]*\"type\":\"TXT\"[^{}]*\"content\":\"$content\"" | head -1 | cut -d , -f 1 | cut -d : -f 2 | tr -d \")
    fi
  fi
  if [ "$_record_id" ]; then
    return 0
  fi

  return 1
}

_katapult_rest() {
  m=$1
  ep="$2"
  data="$3"
  _debug "$ep"

  token_trimmed=$(echo "$KATAPULT_ACCESS_TOKEN" | tr -d '"')

  export _H1="Content-Type: application/json"
  export _H2="Accept: application/json"
  export _H3="Authorization: Bearer $token_trimmed"

  : >"$HTTP_HEADER"

  if [ "$m" != "GET" ]; then
    _debug "rest $m $KATAPULT_URL$ep $data"
    response="$(_post "$data" "$KATAPULT_URL$ep" "" "$m")"
  else
    if _contains "$ep" "?"; then
      sep='&'
    else
      sep='?'
    fi
    page=1
    response=""
    while true; do
      pageresponse="$(_get "$KATAPULT_URL${ep}${sep}page=${page}&per_page=100")"
      if _startswith "$pageresponse" "{\"pagination\":"; then
        if [ -z "$pages" ]; then
          pages=$(echo "$pageresponse" | _egrep_o "^{\"pagination\":{[^}]*\"total_pages\":[0-9]+" 2>/dev/null | rev | cut -d : -f 1 | rev)
        fi
        pageresponse=$(echo "$pageresponse" | sed -n 's/^{\"pagination\":{[^}]*},/{/p')
      fi
      response="$response$pageresponse"
      if [ -z "$pages" ] || [ "$page" -ge "$pages" ]; then
        _debug2 "last page ($page of $pages)"
        break
      fi
    done
  fi

  if [ "$?" != "0" ]; then
    _err "api call failed $ep"
    return 1
  fi

  response="$(echo "$response" | _normalizeJson)"
  _debug2 response "$response"

  _code="$(grep "^HTTP" "$HTTP_HEADER" | _tail_n 1 | cut -d " " -f 2 | tr -d "\\r\\n")"
  if [ "$_code" = "200" ]; then
    _info "api success response ($_code)"
    return 0
  fi

  _err "api error response ($_code)"
  return 1

}
