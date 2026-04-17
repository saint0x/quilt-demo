#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT_DIR"

set -a
source .env
set +a

if ! command -v jq >/dev/null 2>&1; then
  echo "jq is required" >&2
  exit 1
fi

RUN_ID="${RUN_ID:-stress-$(date +%s)}"
PREFIX="${PREFIX:-$RUN_ID}"
ARTIFACT_DIR="${ARTIFACT_DIR:-$ROOT_DIR/.artifacts/$RUN_ID}"
mkdir -p "$ARTIFACT_DIR"

RESULTS_JSON="$ARTIFACT_DIR/results.jsonl"
SUMMARY_JSON="$ARTIFACT_DIR/summary.json"
LOG_TXT="$ARTIFACT_DIR/run.log"
: > "$RESULTS_JSON"
: > "$LOG_TXT"

declare -a CREATED_CONTAINERS=()
declare -a CREATED_VOLUMES=()
declare -a CREATED_FUNCTIONS=()
declare -a CREATED_CLUSTERS=()
declare -a CREATED_SNAPSHOTS=()
declare -a CREATED_TERMINALS=()
declare -a CREATED_IMAGES=()
declare -a CREATED_WORKLOADS=()
declare -a CREATED_NODES=()

TENANT_ID=""
API_OK=0

log() {
  printf '[%s] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" | tee -a "$LOG_TXT" >&2
}

record_result() {
  local status="$1"
  local kind="$2"
  local name="$3"
  local code="$4"
  local detail="$5"
  jq -nc \
    --arg status "$status" \
    --arg kind "$kind" \
    --arg name "$name" \
    --arg code "$code" \
    --arg detail "$detail" \
    '{status:$status,kind:$kind,name:$name,code:$code,detail:$detail,ts:now|floor}' \
    >> "$RESULTS_JSON"
}

api() {
  local method="$1"
  local path="$2"
  local body="${3-}"
  local extra_headers="${4-}"
  local body_file code_file curl_exit
  body_file="$(mktemp)"
  code_file="$(mktemp)"
  local -a cmd=(curl -sS -X "$method" -H "X-Api-Key: $QUILT_API_KEY")
  if [[ -n "$extra_headers" ]]; then
    while IFS= read -r header; do
      [[ -z "$header" ]] && continue
      cmd+=(-H "$header")
    done <<< "$extra_headers"
  fi
  if [[ -n "$body" ]]; then
    cmd+=(-H "Content-Type: application/json" --data "$body")
  fi
  cmd+=(-o "$body_file" -w "%{http_code}" "$QUILT_BASE_URL$path")
  if ! "${cmd[@]}" > "$code_file"; then
    curl_exit=$?
    printf '{"http_code":"000","body_file":"%s","curl_exit":"%s"}\n' "$body_file" "$curl_exit"
    rm -f "$code_file"
    return 0
  fi
  printf '{"http_code":"%s","body_file":"%s","curl_exit":"0"}\n' "$(cat "$code_file")" "$body_file"
  rm -f "$code_file"
}

body_slurp() {
  local file="$1"
  jq -Rs . < "$file"
}

assert_http() {
  local label="$1"
  local meta="$2"
  local expected_regex="$3"
  local http_code
  http_code="$(jq -r '.http_code' <<< "$meta")"
  local body_file
  body_file="$(jq -r '.body_file' <<< "$meta")"
  local body_raw
  body_raw="$(cat "$body_file")"
  if [[ "$http_code" =~ $expected_regex ]]; then
    record_result "pass" "http" "$label" "$http_code" "$body_raw"
    return 0
  fi
  record_result "fail" "http" "$label" "$http_code" "$body_raw"
  log "FAIL $label -> HTTP $http_code"
  return 0
}

require_http() {
  local label="$1"
  local meta="$2"
  local expected_regex="$3"
  assert_http "$label" "$meta" "$expected_regex"
  [[ "$(jq -r '.http_code' <<< "$meta")" =~ $expected_regex ]]
}

extract_json() {
  local meta="$1"
  local filter="$2"
  jq -r "$filter" "$(jq -r '.body_file' <<< "$meta")"
}

poll_operation() {
  local operation_id="$1"
  local extra_headers="${2-}"
  local attempts="${3:-60}"
  local delay="${4:-2}"
  local i meta status
  if [[ -z "$operation_id" || "$operation_id" == "null" ]]; then
    record_result "fail" "operation" "missing-operation-id" "n/a" "attempted to poll empty operation id"
    return 1
  fi
  for ((i=0; i<attempts; i++)); do
    meta="$(api GET "/api/operations/$operation_id" "" "$extra_headers")"
    status="$(extract_json "$meta" '.status // .operation.status // empty')"
    case "$status" in
      succeeded)
        record_result "pass" "operation" "$operation_id" "$(jq -r '.http_code' <<< "$meta")" "$(cat "$(jq -r '.body_file' <<< "$meta")")"
        echo "$meta"
        return 0
        ;;
      failed|cancelled|timed_out)
        record_result "fail" "operation" "$operation_id" "$(jq -r '.http_code' <<< "$meta")" "$(cat "$(jq -r '.body_file' <<< "$meta")")"
        echo "$meta"
        return 1
        ;;
    esac
    sleep "$delay"
  done
  record_result "fail" "operation" "$operation_id" "timeout" "timed out polling operation"
  return 1
}

poll_ready() {
  local container_id="$1"
  local attempts="${2:-45}"
  local i meta exec_ready state
  if [[ -z "$container_id" || "$container_id" == "null" ]]; then
    record_result "fail" "ready" "missing-container-id" "n/a" "attempted to poll empty container id"
    return 1
  fi
  for ((i=0; i<attempts; i++)); do
    meta="$(api GET "/api/containers/$container_id/ready")"
    exec_ready="$(extract_json "$meta" '.exec_ready // false')"
    state="$(extract_json "$meta" '.state // empty')"
    if [[ "$exec_ready" == "true" ]]; then
      record_result "pass" "ready" "$container_id" "$(jq -r '.http_code' <<< "$meta")" "$(cat "$(jq -r '.body_file' <<< "$meta")")"
      echo "$meta"
      return 0
    fi
    if [[ "$state" == "error" ]]; then
      record_result "fail" "ready" "$container_id" "$(jq -r '.http_code' <<< "$meta")" "$(cat "$(jq -r '.body_file' <<< "$meta")")"
      echo "$meta"
      return 1
    fi
    sleep 2
  done
  record_result "fail" "ready" "$container_id" "timeout" "container did not become exec_ready"
  return 1
}

cleanup() {
  log "cleanup starting"
  local id meta operation_id
  for id in "${CREATED_TERMINALS[@]}"; do
    api DELETE "/api/terminal/sessions/$id" >/dev/null || true
  done
  for id in "${CREATED_WORKLOADS[@]}"; do
    local cluster_id="${id%%:*}"
    local workload_id="${id##*:}"
    api DELETE "/api/clusters/$cluster_id/workloads/$workload_id" >/dev/null || true
  done
  for id in "${CREATED_NODES[@]}"; do
    local cluster_id="${id%%:*}"
    local node_id="${id##*:}"
    api POST "/api/agent/clusters/$cluster_id/nodes/$node_id/deregister" "" "X-Quilt-Node-Token: ${NODE_TOKEN:-}" >/dev/null || true
  done
  for id in "${CREATED_FUNCTIONS[@]}"; do
    api DELETE "/api/functions/$id" >/dev/null || true
  done
  for id in "${CREATED_CONTAINERS[@]}"; do
    meta="$(api DELETE "/api/containers/$id")" || true
    operation_id="$(extract_json "$meta" '.operation_id // empty' 2>/dev/null || true)"
    [[ -n "$operation_id" ]] && poll_operation "$operation_id" >/dev/null || true
  done
  for id in "${CREATED_SNAPSHOTS[@]}"; do
    api DELETE "/api/snapshots/$id" "" "X-Tenant-Id: $TENANT_ID" >/dev/null || true
  done
  for id in "${CREATED_VOLUMES[@]}"; do
    meta="$(api DELETE "/api/volumes/$id")" || true
    operation_id="$(extract_json "$meta" '.operation_id // empty' 2>/dev/null || true)"
    [[ -n "$operation_id" ]] && poll_operation "$operation_id" >/dev/null || true
  done
  for id in "${CREATED_IMAGES[@]}"; do
    api DELETE "/api/oci/images?reference=$id" >/dev/null || true
  done
  for id in "${CREATED_CLUSTERS[@]}"; do
    api DELETE "/api/clusters/$id" >/dev/null || true
  done
  log "cleanup finished"
}

trap cleanup EXIT

test_health_and_discovery() {
  log "health and discovery"
  local meta
  meta="$(api GET /health)"
  assert_http "GET /health" "$meta" '^200$'
  meta="$(api GET /api/system/info)"
  assert_http "GET /api/system/info" "$meta" '^200$'
  for concern in containers functions elasticity oci icc; do
    for suffix in help examples health; do
      meta="$(api GET "/api/$concern/$suffix")"
      assert_http "GET /api/$concern/$suffix" "$meta" '^200$'
    done
  done
  meta="$(api GET /api/containers)"
  assert_http "GET /api/containers" "$meta" '^200$'
  TENANT_ID="$(extract_json "$meta" '.containers[0].tenant_id // empty')"
  if [[ -z "$TENANT_ID" ]]; then
    record_result "fail" "setup" "tenant_id" "n/a" "could not infer tenant id from /api/containers"
    exit 1
  fi
  record_result "pass" "setup" "tenant_id" "200" "$TENANT_ID"
  API_OK=1
}

test_volume_and_container_flow() {
  log "volume and container flow"
  local volume="${PREFIX}-vol"
  local volume2="${volume}-renamed"
  local container="${PREFIX}-ctr"
  local container2="${PREFIX}-ctr2"
  local batch0="${PREFIX}-batch-0"
  local batch1="${PREFIX}-batch-1"
  local meta operation_id container_id clone_id fork_id snap_id session_id

  meta="$(api POST /api/volumes "$(jq -nc --arg name "$volume" '{name:$name,driver:"local",labels:{suite:"agents-doc",run:"stress"}}')")"
  require_http "POST /api/volumes" "$meta" '^201$|^200$'
  CREATED_VOLUMES+=("$volume")

  assert_http "GET /api/volumes/$volume" "$(api GET "/api/volumes/$volume")" '^200$'
  assert_http "GET /api/volumes/$volume/inspect" "$(api GET "/api/volumes/$volume/inspect")" '^200$'
  assert_http "GET /api/volumes/$volume/ls" "$(api GET "/api/volumes/$volume/ls")" '^200$'

  local file_payload
  file_payload="$(printf 'stress-file-%s\n' "$RUN_ID" | base64 -w0 | jq -nc --arg content "$(cat)" '{path:"/hello.txt",content:$content,mode:644}')"
  assert_http "POST /api/volumes/$volume/files" "$(api POST "/api/volumes/$volume/files" "$file_payload")" '^200$|^201$'
  assert_http "GET /api/volumes/$volume/files/hello.txt" "$(api GET "/api/volumes/$volume/files/hello.txt")" '^200$'

  local tarball
  tarball="$(mktemp)"
  local srcdir
  srcdir="$(mktemp -d)"
  printf 'archive-%s\n' "$RUN_ID" > "$srcdir/archive.txt"
  tar -C "$srcdir" -czf "$tarball" .
  local archive_payload
  archive_payload="$(jq -nc --arg content "$(base64 -w0 "$tarball")" '{content:$content,strip_components:0,path:"/archive"}')"
  meta="$(api POST "/api/volumes/$volume/archive" "$archive_payload")"
  assert_http "POST /api/volumes/$volume/archive" "$meta" '^202$'
  operation_id="$(extract_json "$meta" '.operation_id')"
  poll_operation "$operation_id" >/dev/null

  assert_http "POST /api/volumes/$volume/rename" "$(api POST "/api/volumes/$volume/rename" "$(jq -nc --arg new_name "$volume2" '{new_name:$new_name}')")" '^200$'
  CREATED_VOLUMES=("${volume2}")

  meta="$(api POST /api/containers "$(jq -nc --arg name "$container" --arg vol "$volume2:/workspace" '{name:$name,image:"prod",strict:true,working_directory:"/workspace",memory_limit_mb:256,cpu_limit_percent:25,volumes:[$vol],environment:{HELLO:"world"},command:["/bin/sh","-lc","echo boot > /workspace/boot.txt; sleep 300"]}')")"
  require_http "POST /api/containers" "$meta" '^202$'
  operation_id="$(extract_json "$meta" '.operation_id')"
  meta="$(poll_operation "$operation_id")"
  container_id="$(extract_json "$meta" '.resource_id // .container_id // .metadata.container_id // empty')"
  if [[ -z "$container_id" ]]; then
    container_id="$(api GET "/api/containers/by-name/$container" | jq -r '.body_file' | xargs jq -r '.container_id')"
  fi
  CREATED_CONTAINERS+=("$container_id")

  require_http "GET /api/containers/by-name/$container" "$(api GET "/api/containers/by-name/$container")" '^200$'
  require_http "GET /api/containers/$container_id" "$(api GET "/api/containers/$container_id")" '^200$'
  poll_ready "$container_id" >/dev/null
  assert_http "GET /api/containers/$container_id/metrics" "$(api GET "/api/containers/$container_id/metrics")" '^200$'
  assert_http "GET /api/containers/$container_id/logs?limit=50" "$(api GET "/api/containers/$container_id/logs?limit=50")" '^200$'
  assert_http "GET /api/containers/$container_id/env" "$(api GET "/api/containers/$container_id/env")" '^200$'
  assert_http "PATCH /api/containers/$container_id/env" "$(api PATCH "/api/containers/$container_id/env" '{"environment":{"PATCHED":"1"}}')" '^200$'
  assert_http "PUT /api/containers/$container_id/env" "$(api PUT "/api/containers/$container_id/env" '{"environment":{"REPLACED":"1"}}')" '^200$'

  meta="$(api POST "/api/containers/$container_id/exec" '{"command":["/bin/sh","-lc","echo exec-ok && ls -la /workspace"],"workdir":"/workspace","timeout_ms":30000}')"
  require_http "POST /api/containers/$container_id/exec" "$meta" '^200$'
  assert_http "GET /api/containers/$container_id/processes" "$(api GET "/api/containers/$container_id/processes")" '^200$'

  meta="$(api POST "/api/containers/$container_id/archive" "$archive_payload")"
  assert_http "POST /api/containers/$container_id/archive" "$meta" '^202$'
  operation_id="$(extract_json "$meta" '.operation_id')"
  poll_operation "$operation_id" >/dev/null

  assert_http "GET /api/containers/$container_id/network" "$(api GET "/api/containers/$container_id/network")" '^200$'
  assert_http "GET /api/containers/$container_id/network/diagnostics" "$(api GET "/api/containers/$container_id/network/diagnostics")" '^200$'
  assert_http "GET /api/containers/$container_id/egress" "$(api GET "/api/containers/$container_id/egress")" '^200$'
  assert_http "POST /api/containers/$container_id/routes" "$(api POST "/api/containers/$container_id/routes" '{"destination":"10.0.0.0/24"}')" '^200$|^201$'
  assert_http "DELETE /api/containers/$container_id/routes" "$(api DELETE "/api/containers/$container_id/routes" '{"destination":"10.0.0.0/24"}')" '^200$'
  assert_http "GET /api/monitors/$container_id" "$(api GET "/api/monitors/$container_id")" '^200$'
  assert_http "GET /api/containers/$container_id/cleanup/tasks" "$(api GET "/api/containers/$container_id/cleanup/tasks")" '^200$'

  meta="$(api POST /api/terminal/sessions "$(jq -nc --arg cid "$container_id" '{container_id:$cid,cols:100,rows:30,shell:"/bin/bash"}')")"
  assert_http "POST /api/terminal/sessions" "$meta" '^201$'
  session_id="$(extract_json "$meta" '.session_id')"
  CREATED_TERMINALS+=("$session_id")
  assert_http "GET /api/terminal/sessions/$session_id" "$(api GET "/api/terminal/sessions/$session_id")" '^200$'
  assert_http "POST /api/terminal/sessions/$session_id/resize" "$(api POST "/api/terminal/sessions/$session_id/resize" '{"cols":120,"rows":40}')" '^200$'

  meta="$(api POST "/api/containers/$container_id/snapshot" '{"consistency_mode":"crash-consistent","network_mode":"reset","volume_mode":"include_named","ttl_seconds":3600,"labels":{"suite":"agents-doc","run":"stress"}}' "X-Tenant-Id: $TENANT_ID")"
  require_http "POST /api/containers/$container_id/snapshot" "$meta" '^202$'
  operation_id="$(extract_json "$meta" '.operation_id')"
  meta="$(poll_operation "$operation_id" "X-Tenant-Id: $TENANT_ID")"
  snap_id="$(extract_json "$meta" '.snapshot_id // .resource_id // .metadata.snapshot_id // empty')"
  if [[ -z "$snap_id" ]]; then
    snap_id="$(api GET "/api/snapshots?container_id=$container_id" "" "X-Tenant-Id: $TENANT_ID" | jq -r '.body_file' | xargs jq -r '.snapshots[-1].snapshot_id // .snapshots[-1].id')"
  fi
  CREATED_SNAPSHOTS+=("$snap_id")
  assert_http "GET /api/snapshots" "$(api GET /api/snapshots "" "X-Tenant-Id: $TENANT_ID")" '^200$'
  assert_http "GET /api/snapshots/$snap_id" "$(api GET "/api/snapshots/$snap_id" "" "X-Tenant-Id: $TENANT_ID")" '^200$'
  assert_http "GET /api/snapshots/$snap_id/lineage" "$(api GET "/api/snapshots/$snap_id/lineage" "" "X-Tenant-Id: $TENANT_ID")" '^200$'

  meta="$(api POST "/api/snapshots/$snap_id/clone" "$(jq -nc --arg name "${PREFIX}-clone" '{resume_policy:"immediate",name:$name,labels:{suite:"agents-doc"}}')" "X-Tenant-Id: $TENANT_ID")"
  assert_http "POST /api/snapshots/$snap_id/clone" "$meta" '^202$'
  operation_id="$(extract_json "$meta" '.operation_id')"
  meta="$(poll_operation "$operation_id" "X-Tenant-Id: $TENANT_ID")"
  clone_id="$(extract_json "$meta" '.container_id // .resource_id // .metadata.container_id // empty')"
  [[ -n "$clone_id" ]] && CREATED_CONTAINERS+=("$clone_id")

  meta="$(api POST "/api/containers/$container_id/fork" "$(jq -nc --arg name "${PREFIX}-fork" '{consistency_mode:"crash-consistent",network_mode:"reset",volume_mode:"exclude",resume_policy:"immediate",name:$name,labels:{suite:"agents-doc"}}')" "X-Tenant-Id: $TENANT_ID")"
  assert_http "POST /api/containers/$container_id/fork" "$meta" '^202$'
  operation_id="$(extract_json "$meta" '.operation_id')"
  meta="$(poll_operation "$operation_id")"
  fork_id="$(extract_json "$meta" '.container_id // .resource_id // .metadata.container_id // empty')"
  [[ -n "$fork_id" ]] && CREATED_CONTAINERS+=("$fork_id")

  assert_http "POST /api/containers/$container_id/rename" "$(api POST "/api/containers/$container_id/rename" "$(jq -nc --arg new_name "$container2" '{new_name:$new_name}')")" '^200$'

  meta="$(api POST /api/containers/batch "$(jq -nc --arg n0 "$batch0" --arg n1 "$batch1" '{items:[{name:$n0,image:"prod",command:["/bin/sh","-lc","sleep 120"]},{name:$n1,image:"prod",command:["/bin/sh","-lc","echo batch && sleep 120"]}]}' )")"
  assert_http "POST /api/containers/batch" "$meta" '^202$'
  operation_id="$(extract_json "$meta" '.operation_id')"
  poll_operation "$operation_id" >/dev/null || true
  for name in "$batch0" "$batch1"; do
    meta="$(api GET "/api/containers/by-name/$name")"
    if [[ "$(jq -r '.http_code' <<< "$meta")" == "200" ]]; then
      CREATED_CONTAINERS+=("$(extract_json "$meta" '.container_id')")
      poll_ready "$(extract_json "$meta" '.container_id')" >/dev/null || true
    fi
  done

  meta="$(api POST "/api/containers/$container_id/stop")"
  assert_http "POST /api/containers/$container_id/stop" "$meta" '^202$'
  operation_id="$(extract_json "$meta" '.operation_id')"
  poll_operation "$operation_id" >/dev/null

  meta="$(api POST "/api/containers/$container_id/resume")"
  assert_http "POST /api/containers/$container_id/resume" "$meta" '^202$'
  operation_id="$(extract_json "$meta" '.operation_id')"
  poll_operation "$operation_id" >/dev/null
  poll_ready "$container_id" >/dev/null || true

  rm -rf "$srcdir" "$tarball"
}

test_oci() {
  log "oci flow"
  local ref="quilt.local/${PREFIX}/demo:latest"
  local oci_container="${PREFIX}-oci"
  local meta operation_id context_id container_id
  assert_http "GET /api/oci/images" "$(api GET /api/oci/images)" '^200$'
  assert_http "POST /api/oci/images/pull" "$(api POST /api/oci/images/pull '{"reference":"docker.io/library/alpine:3.20"}')" '^200$'
  assert_http "GET /api/oci/images/inspect" "$(api GET '/api/oci/images/inspect?reference=docker.io/library/alpine:3.20')" '^200$'
  assert_http "GET /api/oci/images/history" "$(api GET '/api/oci/images/history?reference=docker.io/library/alpine:3.20')" '^200$'

  local build_dir tarball
  build_dir="$(mktemp -d)"
  cat > "$build_dir/Dockerfile" <<'EOF'
FROM docker.io/library/alpine:3.20
WORKDIR /app
RUN printf 'hello from quilt\n' > /app/message.txt
CMD ["sh","-lc","cat /app/message.txt && sleep 30"]
EOF
  tarball="$(mktemp)"
  tar -C "$build_dir" -czf "$tarball" .
  meta="$(api POST /api/build-contexts "$(jq -nc --arg content "$(base64 -w0 "$tarball")" '{content:$content}')")"
  assert_http "POST /api/build-contexts" "$meta" '^200$|^201$'
  context_id="$(extract_json "$meta" '.context_id')"
  meta="$(api POST /api/oci/images/build "$(jq -nc --arg ctx "$context_id" --arg ref "$ref" '{context_id:$ctx,image_reference:$ref,dockerfile_path:"Dockerfile"}')")"
  assert_http "POST /api/oci/images/build" "$meta" '^202$'
  operation_id="$(extract_json "$meta" '.operation_id')"
  poll_operation "$operation_id" >/dev/null
  CREATED_IMAGES+=("$ref")

  meta="$(api POST /api/containers "$(jq -nc --arg name "$oci_container" --arg ref "$ref" '{name:$name,image:$ref,oci:true,command:["sh","-lc","cat /app/message.txt && sleep 60"]}')")"
  assert_http "POST /api/containers (oci)" "$meta" '^202$'
  operation_id="$(extract_json "$meta" '.operation_id')"
  poll_operation "$operation_id" >/dev/null
  meta="$(api GET "/api/containers/by-name/$oci_container")"
  if [[ "$(jq -r '.http_code' <<< "$meta")" == "200" ]]; then
    container_id="$(extract_json "$meta" '.container_id')"
    CREATED_CONTAINERS+=("$container_id")
  fi
  rm -rf "$build_dir" "$tarball"
}

test_gui() {
  log "gui flow"
  local gui_name="${PREFIX}-gui"
  local meta operation_id container_id
  meta="$(api POST /api/containers "$(jq -nc --arg name "$gui_name" '{name:$name,image:"prod-gui",memory_limit_mb:1024,cpu_limit_percent:50,strict:true,environment:{FOO:"bar"}}')")"
  assert_http "POST /api/containers (gui)" "$meta" '^202$'
  operation_id="$(extract_json "$meta" '.operation_id')"
  poll_operation "$operation_id" >/dev/null
  meta="$(api GET "/api/containers/by-name/$gui_name")"
  if [[ "$(jq -r '.http_code' <<< "$meta")" == "200" ]]; then
    container_id="$(extract_json "$meta" '.container_id')"
    CREATED_CONTAINERS+=("$container_id")
    poll_ready "$container_id" >/dev/null || true
    assert_http "GET /api/containers/$container_id/gui-url" "$(api GET "/api/containers/$container_id/gui-url")" '^200$'
  fi
}

test_functions_and_elasticity() {
  log "functions and elasticity"
  local fn_name="${PREFIX}-fn"
  local meta function_id invocation_id container_meta container_id op_id
  local headers
  headers=$'X-Tenant-Id: '"$TENANT_ID"

  assert_http "GET /api/elasticity/health" "$(api GET /api/elasticity/health)" '^200$'
  assert_http "GET /api/elasticity/node/status" "$(api GET /api/elasticity/node/status "" "$headers")" '^200$'
  assert_http "GET /api/elasticity/control/contract" "$(api GET /api/elasticity/control/contract "" "$headers")" '^200$'

  meta="$(api POST /api/functions "$(jq -nc --arg name "$fn_name" '{name:$name,description:"stress test function",handler:"echo ${PAYLOAD:-none}",runtime:"shell",memory_limit_mb:256,cpu_limit_percent:25,timeout_seconds:30,min_instances:0,max_instances:2,cleanup_on_exit:true}')")"
  assert_http "POST /api/functions" "$meta" '^200$|^201$'
  function_id="$(extract_json "$meta" '.function_id // .id')"
  CREATED_FUNCTIONS+=("$function_id")
  assert_http "GET /api/functions" "$(api GET /api/functions)" '^200$'
  assert_http "GET /api/functions/$function_id" "$(api GET "/api/functions/$function_id")" '^200$'
  assert_http "GET /api/functions/by-name/$fn_name" "$(api GET "/api/functions/by-name/$fn_name")" '^200$'
  assert_http "POST /api/functions/$function_id/deploy" "$(api POST "/api/functions/$function_id/deploy")" '^200$'
  assert_http "GET /api/functions/$function_id/pool" "$(api GET "/api/functions/$function_id/pool")" '^200$'
  meta="$(api POST "/api/functions/$function_id/invoke" '{"payload":"stress-payload","environment":{"PAYLOAD":"stress-payload"},"timeout_seconds":30}')"
  assert_http "POST /api/functions/$function_id/invoke" "$meta" '^200$'
  invocation_id="$(extract_json "$meta" '.invocation_id')"
  assert_http "POST /api/functions/invoke/$fn_name" "$(api POST "/api/functions/invoke/$fn_name" '{"payload":"by-name","environment":{"PAYLOAD":"by-name"},"timeout_seconds":30}')" '^200$'
  assert_http "GET /api/functions/$function_id/invocations?limit=5" "$(api GET "/api/functions/$function_id/invocations?limit=5")" '^200$'
  assert_http "GET /api/functions/$function_id/invocations/$invocation_id" "$(api GET "/api/functions/$function_id/invocations/$invocation_id")" '^200$'
  assert_http "GET /api/functions/$function_id/versions" "$(api GET "/api/functions/$function_id/versions")" '^200$'
  assert_http "GET /api/functions/pool/stats" "$(api GET /api/functions/pool/stats)" '^200$'

  assert_http "PUT /api/functions/$function_id" "$(api PUT "/api/functions/$function_id" '{"description":"stress test function v2","handler":"echo updated","runtime":"shell","memory_limit_mb":256,"cpu_limit_percent":25,"timeout_seconds":30,"min_instances":0,"max_instances":2,"cleanup_on_exit":true}')" '^200$'
  assert_http "POST /api/functions/$function_id/rollback" "$(api POST "/api/functions/$function_id/rollback" '{"version":1}')" '^200$'
  assert_http "POST /api/functions/$function_id/pause" "$(api POST "/api/functions/$function_id/pause")" '^200$'
  assert_http "POST /api/functions/$function_id/resume" "$(api POST "/api/functions/$function_id/resume")" '^200$'

  container_meta="$(api GET "/api/containers?state=running")"
  container_id="$(extract_json "$container_meta" ".containers[] | select(.name|startswith(\"${PREFIX}\")) | .container_id" | head -n1)"
  if [[ -n "$container_id" ]]; then
    assert_http "POST /api/elasticity/containers/$container_id/resize" "$(api POST "/api/elasticity/containers/$container_id/resize" '{"memory_limit_mb":384,"cpu_limit_percent":35}' "$headers")" '^200$'
    meta="$(api POST "/api/elasticity/control/containers/$container_id/resize" '{"memory_limit_mb":448,"cpu_limit_percent":40}' "$headers"$'\n''Idempotency-Key: '"$PREFIX"'-ctr-resize'$'\n''X-Orch-Action-Id: '"$PREFIX"'-ctr-action')"
    assert_http "POST /api/elasticity/control/containers/$container_id/resize" "$meta" '^200$|^202$'
    op_id="$(extract_json "$meta" '.operation_id // empty')"
    [[ -n "$op_id" ]] && assert_http "GET /api/elasticity/control/operations/$op_id" "$(api GET "/api/elasticity/control/operations/$op_id" "" "$headers")" '^200$'
    assert_http "GET /api/elasticity/control/actions/${PREFIX}-ctr-action/operations" "$(api GET "/api/elasticity/control/actions/${PREFIX}-ctr-action/operations" "" "$headers")" '^200$'
  fi
  assert_http "POST /api/elasticity/functions/$function_id/pool-target" "$(api POST "/api/elasticity/functions/$function_id/pool-target" '{"min_instances":1,"max_instances":2}' "$headers")" '^200$'
  meta="$(api POST "/api/elasticity/control/functions/$function_id/pool-target" '{"min_instances":1,"max_instances":2}' "$headers"$'\n''Idempotency-Key: '"$PREFIX"'-fn-pool'$'\n''X-Orch-Action-Id: '"$PREFIX"'-fn-action')"
  assert_http "POST /api/elasticity/control/functions/$function_id/pool-target" "$meta" '^200$|^202$'
}

test_icc() {
  log "icc flow"
  local env_b64="CAESD21zZ19leGFtcGxlXzAwMRoPcmVxX2V4YW1wbGVfMDAxOhBjb250YWluZXItc291cmNlQg1jb250YWluZXItMTIzWICwj+ayd2Dg1ANoAXoVChMKCnRleHQvcGxhaW4SBWhlbGxv"
  local meta msg_id seq
  assert_http "GET /api/icc" "$(api GET /api/icc)" '^200$'
  assert_http "GET /api/icc/streams" "$(api GET /api/icc/streams)" '^200$'
  assert_http "GET /api/icc/schema" "$(api GET /api/icc/schema)" '^200$'
  assert_http "GET /api/icc/types" "$(api GET /api/icc/types)" '^200$'
  assert_http "GET /api/icc/proto" "$(api GET /api/icc/proto)" '^200$'
  assert_http "GET /api/icc/descriptor" "$(api GET /api/icc/descriptor)" '^200$'
  meta="$(api POST /api/icc/messages "$(jq -nc --arg env "$env_b64" '{envelope_b64:$env}')")"
  assert_http "POST /api/icc/messages" "$meta" '^200$'
  msg_id="$(extract_json "$meta" '.envelope_summary.msg_id // empty')"
  seq="$(extract_json "$meta" '.stream_seq // empty')"
  assert_http "POST /api/icc/publish" "$(api POST /api/icc/publish "$(jq -nc --arg env "$env_b64" '{envelope_b64:$env}')")" '^200$'
  assert_http "GET /api/icc/messages?container_id=container-123&limit=10" "$(api GET '/api/icc/messages?container_id=container-123&limit=10')" '^200$'
  assert_http "GET /api/icc/inbox/container-123" "$(api GET '/api/icc/inbox/container-123?limit=10')" '^200$'
  [[ -n "$msg_id" ]] && assert_http "POST /api/icc/messages/$msg_id/ack" "$(api POST "/api/icc/messages/$msg_id/ack" '{"msg_id":"msg_example_001","action":"ack","reason":"handled"}')" '^200$'
  assert_http "POST /api/icc/ack" "$(api POST /api/icc/ack '{"msg_id":"msg_example_001","action":"ack","reason":"handled"}')" '^200$'
  assert_http "POST /api/icc/replay" "$(api POST /api/icc/replay '{"container_id":"container-123","state":"acked","limit":10}')" '^200$'
  assert_http "POST /api/icc/inbox/container-123/replay" "$(api POST /api/icc/inbox/container-123/replay '{"container_id":"container-123","state":"acked","limit":10}')" '^200$'
  assert_http "GET /api/icc/containers/container-123/state-version" "$(api GET /api/icc/containers/container-123/state-version)" '^200$|^404$'
  assert_http "GET /api/icc/dlq" "$(api GET /api/icc/dlq)" '^200$'
  [[ -n "$seq" ]] && assert_http "POST /api/icc/dlq/$seq/replay" "$(api POST "/api/icc/dlq/$seq/replay" '{}')" '^200$|^404$'
}

test_clusters_and_k8s() {
  log "clusters and k8s"
  local cluster_name="${PREFIX}-cluster"
  local node_name="${PREFIX}-node"
  local workload_name="${PREFIX}-workload"
  local meta cluster_id join_token node_id workload_id node_token placement_id

  meta="$(api POST /api/clusters "$(jq -nc --arg name "$cluster_name" '{name:$name,pod_cidr:"10.71.0.0/16",node_cidr_prefix:24}')")"
  assert_http "POST /api/clusters" "$meta" '^200$|^201$'
  cluster_id="$(extract_json "$meta" '.id // .cluster_id')"
  CREATED_CLUSTERS+=("$cluster_id")
  assert_http "GET /api/clusters/$cluster_id" "$(api GET "/api/clusters/$cluster_id")" '^200$'
  assert_http "GET /api/clusters/$cluster_id/capabilities" "$(api GET "/api/clusters/$cluster_id/capabilities")" '^200$'
  assert_http "GET /api/clusters/$cluster_id/nodes" "$(api GET "/api/clusters/$cluster_id/nodes")" '^200$'

  meta="$(api POST "/api/clusters/$cluster_id/join-tokens" '{"ttl_seconds":600,"max_uses":1}')"
  assert_http "POST /api/clusters/$cluster_id/join-tokens" "$meta" '^200$|^201$'
  join_token="$(extract_json "$meta" '.join_token // .token')"

  meta="$(api POST "/api/agent/clusters/$cluster_id/nodes/register" "$(jq -nc --arg name "$node_name" '{name:$name,public_ip:"203.0.113.10",private_ip:"10.0.0.10",agent_version:"stress-agent",labels:{suite:"agents-doc"},bridge_name:"quilt0",dns_port:1053,egress_limit_mbit:1000,gpu_devices:[]}')" "X-Quilt-Join-Token: $join_token")"
  assert_http "POST /api/agent/clusters/$cluster_id/nodes/register" "$meta" '^200$|^201$'
  node_id="$(extract_json "$meta" '.node_id // .id')"
  node_token="$(extract_json "$meta" '.node_token // empty')"
  [[ -n "$node_id" ]] && CREATED_NODES+=("$cluster_id:$node_id")
  [[ -n "$node_token" ]] && NODE_TOKEN="$node_token"

  if [[ -n "${NODE_TOKEN:-}" && -n "$node_id" ]]; then
    assert_http "POST /api/agent/clusters/$cluster_id/nodes/$node_id/heartbeat" "$(api POST "/api/agent/clusters/$cluster_id/nodes/$node_id/heartbeat" '{"state":"ready","labels":{"suite":"agents-doc"},"gpu_devices":[]}' "X-Quilt-Node-Token: $NODE_TOKEN")" '^200$'
    assert_http "GET /api/agent/clusters/$cluster_id/nodes/$node_id/allocation" "$(api GET "/api/agent/clusters/$cluster_id/nodes/$node_id/allocation" "" "X-Quilt-Node-Token: $NODE_TOKEN")" '^200$'
    assert_http "GET /api/agent/clusters/$cluster_id/nodes/$node_id/placements" "$(api GET "/api/agent/clusters/$cluster_id/nodes/$node_id/placements" "" "X-Quilt-Node-Token: $NODE_TOKEN")" '^200$'
  fi

  meta="$(api POST "/api/clusters/$cluster_id/workloads" "$(jq -nc --arg name "$workload_name" '{name:$name,replicas:1,command:["sh","-lc","echo hi; tail -f /dev/null"],memory_limit_mb:256,cpu_limit_percent:25}')" )"
  assert_http "POST /api/clusters/$cluster_id/workloads" "$meta" '^200$|^201$'
  workload_id="$(extract_json "$meta" '.workload_id // .id')"
  [[ -n "$workload_id" ]] && CREATED_WORKLOADS+=("$cluster_id:$workload_id")
  assert_http "GET /api/clusters/$cluster_id/workloads" "$(api GET "/api/clusters/$cluster_id/workloads")" '^200$'
  assert_http "GET /api/clusters/$cluster_id/workloads/$workload_id" "$(api GET "/api/clusters/$cluster_id/workloads/$workload_id")" '^200$'
  assert_http "PUT /api/clusters/$cluster_id/workloads/$workload_id" "$(api PUT "/api/clusters/$cluster_id/workloads/$workload_id" "$(jq -nc --arg name "$workload_name" '{name:$name,replicas:2,command:["sh","-lc","echo updated; tail -f /dev/null"],memory_limit_mb:256,cpu_limit_percent:25}')" )" '^200$'
  assert_http "POST /api/clusters/$cluster_id/reconcile" "$(api POST "/api/clusters/$cluster_id/reconcile")" '^200$|^202$'
  assert_http "GET /api/clusters/$cluster_id/placements" "$(api GET "/api/clusters/$cluster_id/placements")" '^200$'

  if [[ -n "$workload_id" ]]; then
    local headers
    headers=$'X-Tenant-Id: '"$TENANT_ID"$'\n''Idempotency-Key: '"$PREFIX"'-wl-binding'$'\n''X-Orch-Action-Id: '"$PREFIX"'-wl-action'
    assert_http "PUT /api/elasticity/control/workloads/$workload_id/function-binding" "$(api PUT "/api/elasticity/control/workloads/$workload_id/function-binding" '{"function_id":"fn_123"}' "$headers")" '^200$|^202$|^404$'
    assert_http "GET /api/elasticity/control/workloads/$workload_id/function-binding" "$(api GET "/api/elasticity/control/workloads/$workload_id/function-binding" "" "X-Tenant-Id: $TENANT_ID")" '^200$|^404$'
    assert_http "POST /api/elasticity/control/workloads/$workload_id/function-binding/rotate" "$(api POST "/api/elasticity/control/workloads/$workload_id/function-binding/rotate" '{"next_function_id":"fn_456","cutover_at":1893456000}' "$headers")" '^200$|^202$|^404$'
    assert_http "PUT /api/elasticity/control/workloads/$workload_id/placement-preference" "$(api PUT "/api/elasticity/control/workloads/$workload_id/placement-preference" '{"node_group":"group-a","anti_affinity":true}' "$headers")" '^200$|^202$|^404$'
    assert_http "GET /api/elasticity/control/workloads/$workload_id/placement-preference" "$(api GET "/api/elasticity/control/workloads/$workload_id/placement-preference" "" "X-Tenant-Id: $TENANT_ID")" '^200$|^404$'
  fi

  local manifest
  manifest="$(cat <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${PREFIX}-deploy
spec:
  replicas: 1
  selector:
    matchLabels:
      app: ${PREFIX}-deploy
  template:
    metadata:
      labels:
        app: ${PREFIX}-deploy
    spec:
      containers:
        - name: app
          image: nginx:stable
EOF
)"
  assert_http "GET /api/k8s/schema" "$(api GET /api/k8s/schema)" '^200$'
  assert_http "POST /api/k8s/validate" "$(api POST /api/k8s/validate "$(jq -nc --arg manifest "$manifest" '{manifests:$manifest,namespace:"default"}')" )" '^200$|^422$'
  assert_http "POST /api/k8s/diff" "$(api POST /api/k8s/diff "$(jq -nc --arg manifest "$manifest" --arg cid "$cluster_id" '{manifests:$manifest,cluster_id:$cid}')" )" '^200$|^422$'
  assert_http "POST /api/k8s/apply" "$(api POST /api/k8s/apply "$(jq -nc --arg manifest "$manifest" --arg cid "$cluster_id" '{manifests:$manifest,cluster_id:$cid,application:"default"}')" )" '^200$|^202$|^422$'
  assert_http "GET /api/k8s/resources" "$(api GET /api/k8s/resources)" '^200$'
  assert_http "POST /api/k8s/export" "$(api POST /api/k8s/export "$(jq -nc --arg cid "$cluster_id" '{cluster_id:$cid}')" )" '^200$|^422$'
}

test_negative_contracts() {
  log "negative contract checks"
  assert_http "GET /api/snapshots missing tenant" "$(api GET /api/snapshots)" '^400$'
  assert_http "POST /api/elasticity/control/node-groups/group-a/scale missing headers" "$(api POST /api/elasticity/control/node-groups/group-a/scale '{"delta_units":1}')" '^400$|^401$'
  assert_http "POST /api/containers gpu unavailable" "$(api POST /api/containers "$(jq -nc --arg name "${PREFIX}-gpu" '{name:$name,image:"prod",gpu_count:1,command:["/bin/sh","-lc","nvidia-smi"]}')" )" '^4'
}

build_summary() {
  jq -s '
    {
      total: length,
      passed: map(select(.status=="pass")) | length,
      failed: map(select(.status=="fail")) | length,
      failures: map(select(.status=="fail") | {kind,name,code,detail}),
      passed_checks: map(select(.status=="pass") | {kind,name,code})[0:25]
    }' "$RESULTS_JSON" > "$SUMMARY_JSON"
}

main() {
  test_health_and_discovery
  test_volume_and_container_flow
  test_oci
  test_gui
  test_functions_and_elasticity
  test_icc
  test_clusters_and_k8s
  test_negative_contracts
  build_summary
  cat "$SUMMARY_JSON"
}

main "$@"
