#!/usr/bin/env bash
# fm-decision-brief-lib.sh - the captain decision write-up: one stored record per
# held decision, shared by every surface that shows it.
#
# A write-up is the full case for one captain call, authored when the call is
# raised so no surface has to reconstruct it from chat or a report. This library
# is its single owner: the field contract (FM_DECISION_BRIEF_JQ_DEFS), the
# durable location, the normalizing store, and the plain-text rendering.
# bin/fm-captain-hold.sh stores and reads it, bin/fm-bearings-snapshot.sh
# surfaces it, and bin/fm-bearings-board.sh validates the same shape on a board
# card (the board template renders it).
#
# Fields (all strings except options; unknown keys are refused; each text field
# is at most 4000 characters and a write-up carries 1-12 options):
#   question          what is being decided
#   why_it_matters    the consequence of leaving it open or choosing wrongly
#   background        the situation in plain words; blank lines separate paragraphs
#   options[]         {value, label, consequence}: one entry per answer, with what
#                     happens if it is picked; values are unique slugs and never
#                     the reserved `reconcile`
#   recommend_value   OPTIONAL, one of the options' values
#   recommend_reason  why the recommendation is the recommendation
#   asked             OPTIONAL YYYY-MM-DD date the call was raised
#   report            OPTIONAL path or URL of the evidence behind it
#
# The stored file is $DATA/captain-briefs/<task-id>.json: the validated fields in
# a fixed order plus schema=fm-captain-brief.v1, so storing the same write-up
# again rewrites identical bytes. It outlives the hold (the record of what the
# captain was shown), and only an OPEN captain call's write-up is surfaced.

FM_DECISION_BRIEF_SCHEMA=fm-captain-brief.v1

# jq definitions: `brief_valid` is the shape predicate and `brief_normalized`
# the fixed-order projection of a valid write-up. Callers prepend these to their
# own program, the way bin/fm-landed-lib.sh shares FM_LANDED_JQ_DEFS.
# shellcheck disable=SC2016
FM_DECISION_BRIEF_JQ_DEFS='
  def brief_text: type == "string" and test("[^[:space:]]") and length <= 4000;
  def brief_slug: type == "string" and test("^[A-Za-z0-9._-]{1,128}$");
  def brief_date:
    . as $d
    | type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}$")
      and (try (((. + "T00:00:00Z") | fromdateiso8601 | strftime("%Y-%m-%d")) == $d) catch false);
  def brief_option:
    type == "object"
    and ((keys - ["value", "label", "consequence"]) == [])
    and (.value | brief_slug) and (.value != "reconcile")
    and (.label | brief_text) and (.consequence | brief_text);
  def brief_valid:
    type == "object"
    and ((keys - ["schema", "question", "why_it_matters", "background", "options",
                  "recommend_value", "recommend_reason", "asked", "report"]) == [])
    and ((has("schema") | not) or .schema == "fm-captain-brief.v1")
    and (.question | brief_text)
    and (.why_it_matters | brief_text)
    and (.background | brief_text)
    and (.recommend_reason | brief_text)
    and (.options | type == "array" and length >= 1 and length <= 12)
    and ([.options[] | brief_option] | all)
    and (([.options[].value] | length) == ([.options[].value] | unique | length))
    and ((has("recommend_value") | not) or (.recommend_value == null)
         or (.recommend_value as $r | [.options[].value] | index($r) != null))
    and ((has("asked") | not) or (.asked == null) or (.asked | brief_date))
    and ((has("report") | not) or (.report == null) or (.report | brief_text));
  def brief_normalized:
    {schema: "fm-captain-brief.v1", question, why_it_matters, background,
     options: [.options[] | {value, label, consequence}],
     recommend_value: (.recommend_value // null), recommend_reason,
     asked: (.asked // null), report: (.report // null)};
'

fm_decision_brief_dir() {  # <data-dir>
  printf '%s/captain-briefs\n' "$1"
}

fm_decision_brief_path() {  # <data-dir> <task-id>
  printf '%s/%s.json\n' "$(fm_decision_brief_dir "$1")" "$2"
}

# Validate a candidate write-up file and print its normalized JSON.
fm_decision_brief_normalize() {  # <input.json>
  [ -f "$1" ] && [ -r "$1" ] || { echo "write-up file is not readable: $1" >&2; return 1; }
  jq -e "$FM_DECISION_BRIEF_JQ_DEFS"'
    if brief_valid then brief_normalized else error("invalid") end
  ' "$1" 2>/dev/null \
    || { echo "write-up is not a valid $FM_DECISION_BRIEF_SCHEMA record: $1" >&2; return 1; }
}

# Durably store a write-up for a task. A byte-identical stored record is left
# untouched, so re-holding with the same write-up is a no-op.
fm_decision_brief_store() {  # <data-dir> <task-id> <input.json>
  local data=$1 id=$2 input=$3 normalized dir path tmp
  normalized=$(fm_decision_brief_normalize "$input") || return 1
  dir=$(fm_decision_brief_dir "$data")
  path=$(fm_decision_brief_path "$data" "$id")
  if [ -f "$path" ] && [ "$(jq -c . "$path" 2>/dev/null)" = "$(printf '%s' "$normalized" | jq -c .)" ]; then
    return 0
  fi
  mkdir -p "$dir" || { echo "cannot create $dir" >&2; return 1; }
  tmp=$(umask 077; mktemp "$dir/.brief.XXXXXX") || { echo "cannot stage the write-up" >&2; return 1; }
  if ! printf '%s\n' "$normalized" | jq . > "$tmp" || ! mv -f "$tmp" "$path"; then
    rm -f "$tmp"
    echo "cannot store the write-up for $id" >&2
    return 1
  fi
}

# Print the stored write-up JSON; exit 1 when there is none or it is unusable.
fm_decision_brief_read() {  # <data-dir> <task-id>
  local path
  path=$(fm_decision_brief_path "$1" "$2")
  [ -f "$path" ] || return 1
  jq -e "$FM_DECISION_BRIEF_JQ_DEFS"'select(brief_valid) | brief_normalized' "$path" 2>/dev/null
}

# Render a write-up (JSON on stdin) as plain readable text.
fm_decision_brief_render() {
  jq -r '
    def lines: gsub("\r"; "");
    "Decision: \(.question | lines)",
    (if .asked then "Raised: \(.asked)" else empty end),
    "",
    "Why it matters",
    (.why_it_matters | lines),
    "",
    "Background",
    (.background | lines),
    "",
    "Options",
    (.options[] | "- \(.label) [\(.value)]: \(.consequence | lines)"),
    "",
    "Recommendation",
    (if .recommend_value then
       "\(.recommend_value): \(.recommend_reason | lines)"
     else (.recommend_reason | lines) end),
    (if .report then "", "Evidence: \(.report)" else empty end)
  '
}
