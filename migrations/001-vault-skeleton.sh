#!/usr/bin/env bash
# 001 — create the unified vault folder skeleton and seed curated files
# from templates when missing. Idempotent.
set -euo pipefail

# Expects: MEMORIA_VAULT_ROOT, MEMORIA_MACHINE, MEMORIA_REPO_DIR (from env)
TODAY=$(date '+%Y-%m-%d')

mkdir -p \
  "${MEMORIA_VAULT_ROOT}/Memoria/Archivo/conflictos" \
  "${MEMORIA_VAULT_ROOT}/Memoria/Suenos" \
  "${MEMORIA_VAULT_ROOT}/Memoria-CC" \
  "${MEMORIA_VAULT_ROOT}/Lecciones" \
  "${MEMORIA_VAULT_ROOT}/projects" \
  "${MEMORIA_VAULT_ROOT}/daily" \
  "${MEMORIA_VAULT_ROOT}/agents/skills"

render() {
  sed "s|{{MACHINE}}|${MEMORIA_MACHINE}|g; s|{{TODAY}}|${TODAY}|g" "$1" > "$2"
}

TPL="${MEMORIA_REPO_DIR}/templates/memoria-curada"
declare -A SEEDS=(
  ["contexto-reciente.md"]="contexto-reciente.md"
  ["proyectos-activos.md"]="proyectos-activos.md"
  ["personas.md"]="personas.md"
  ["preferencias.md"]="preferencias-jarvis.md"
)
for tpl in "${!SEEDS[@]}"; do
  dest="${MEMORIA_VAULT_ROOT}/Memoria/${SEEDS[$tpl]}"
  [ -f "$dest" ] || render "${TPL}/${tpl}" "$dest"
done

[ -f "${MEMORIA_VAULT_ROOT}/Memoria-CC/MEMORY.md" ] || cat > "${MEMORIA_VAULT_ROOT}/Memoria-CC/MEMORY.md" <<EOF
# Memory Index

EOF

echo "001: vault skeleton ok"
