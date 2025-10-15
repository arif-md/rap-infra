#!/usr/bin/env bash
set -euo pipefail

# Inputs via env:
# - TARGET_ENV
# - MAIL_SERVER, MAIL_USERNAME, MAIL_PASSWORD, MAIL_TO
# - RELEASE_HTML: path to HTML body file (optional; default release-notes.html)
# - RELEASE_BODY: path to text body file (optional; default release-notes.md)
# - SUBJECT_PREFIX: optional prefix for email subject

TARGET_ENV=${TARGET_ENV:-}
MAIL_SERVER=${MAIL_SERVER:-}
MAIL_USERNAME=${MAIL_USERNAME:-}
MAIL_PASSWORD=${MAIL_PASSWORD:-}
MAIL_TO=${MAIL_TO:-}
RELEASE_HTML=${RELEASE_HTML:-release-notes.html}
RELEASE_BODY=${RELEASE_BODY:-release-notes.md}
SUBJECT_PREFIX=${SUBJECT_PREFIX:-}

check_prereqs() {
  local missing=()
  [[ -z "$MAIL_SERVER" ]] && missing+=(MAIL_SERVER)
  [[ -z "$MAIL_USERNAME" ]] && missing+=(MAIL_USERNAME)
  [[ -z "$MAIL_PASSWORD" ]] && missing+=(MAIL_PASSWORD)
  [[ -z "$MAIL_TO" ]] && missing+=(MAIL_TO)
  if (( ${#missing[@]} > 0 )); then
    echo "[email] Missing prerequisites: ${missing[*]}" >&2
    echo "prereqs_ok=false" >> "$GITHUB_OUTPUT"
    return 1
  fi
  echo "prereqs_ok=true" >> "$GITHUB_OUTPUT"
}

compose_subject() {
  local subj
  subj="${SUBJECT_PREFIX:+$SUBJECT_PREFIX }RAP: Promote frontend to ${TARGET_ENV}"
  echo "subject=$subj" >> "$GITHUB_OUTPUT"
}

emit_summary() {
  echo "### Email summary" >> "$GITHUB_STEP_SUMMARY"
  echo "- Target environment: ${TARGET_ENV}" >> "$GITHUB_STEP_SUMMARY"
  echo "- Mail server: ${MAIL_SERVER}" >> "$GITHUB_STEP_SUMMARY"
  echo "- Recipients: ${MAIL_TO}" >> "$GITHUB_STEP_SUMMARY"
  if [[ -f "$RELEASE_BODY" ]]; then
    echo "\n<details><summary>Release notes (text)</summary>" >> "$GITHUB_STEP_SUMMARY"
    printf '\n\n' >> "$GITHUB_STEP_SUMMARY"
    cat "$RELEASE_BODY" >> "$GITHUB_STEP_SUMMARY"
    echo "\n</details>" >> "$GITHUB_STEP_SUMMARY"
  fi
}

# Simple SMTP send using curl (supports basic auth / STARTTLS via smtps scheme if server provides)
send_email() {
  local subject_line html_file text_file
  subject_line="$1"; html_file="$2"; text_file="$3"
  if [[ -z "$subject_line" ]]; then echo "[email] Missing subject" >&2; return 1; fi
  if [[ ! -f "$html_file" ]]; then echo "[email] Missing HTML body: $html_file" >&2; return 1; fi
  local boundary="=====multipart_boundary_$$"
  local payload
  payload=$(mktemp)
  {
    echo "From: ${MAIL_USERNAME}"
    echo "To: ${MAIL_TO}"
    echo "Subject: ${subject_line}"
    echo "MIME-Version: 1.0"
    echo "Content-Type: multipart/alternative; boundary=\"$boundary\""
    echo
    echo "--$boundary"
    echo "Content-Type: text/plain; charset=utf-8"
    echo
    if [[ -f "$text_file" ]]; then cat "$text_file"; else echo "See HTML part."; fi
    echo
    echo "--$boundary"
    echo "Content-Type: text/html; charset=utf-8"
    echo
    cat "$html_file"
    echo
    echo "--$boundary--"
  } > "$payload"

  # Allow server strings like smtp://host:25 or smtps://host:465
  local url="$MAIL_SERVER"
  if ! echo "$url" | grep -Eq '^(smtp|smtps)://'; then url="smtp://${MAIL_SERVER}:25"; fi

  curl -sS --url "$url" \
    --mail-from "$MAIL_USERNAME" \
    --mail-rcpt "$MAIL_TO" \
    --upload-file "$payload" \
    --user "$MAIL_USERNAME:$MAIL_PASSWORD" \
    --ssl-reqd || {
      echo "[email] Email send failed via curl. Check server/credentials." >&2
      return 1
    }
  echo "[email] Email sent"
}
