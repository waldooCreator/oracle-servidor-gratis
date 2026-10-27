#!/usr/bin/env bash
# Intenta crear el servidor gratis (Ampere A1) en Oracle Cloud hasta lograrlo
# o hasta que se acabe el tiempo de esta ejecución.
#
# Variables de entorno:
#   OCI_TENANCY_OCID   compartimento raíz (lo da la API key)
#   SSH_PUBLIC_KEY     llave pública para entrar al servidor
#   NOMBRE             nombre del servidor            (por defecto servidor-nube)
#   SUBRED             nombre de la subred existente  (por defecto nube-publica)
#   DISCO_GB           tamaño del disco               (por defecto 200)
#   MINUTOS            cuánto intentar en esta vuelta (por defecto 50)
#   PAUSA              segundos entre intentos        (por defecto 60)
set -uo pipefail

NOMBRE="${NOMBRE:-servidor-nube}"
SUBRED="${SUBRED:-nube-publica}"
DISCO_GB="${DISCO_GB:-200}"
MINUTOS="${MINUTOS:-50}"
PAUSA="${PAUSA:-60}"
COMP="$OCI_TENANCY_OCID"
# De mayor a menor: si no hay cupo para el grande, se prueba uno más pequeño.
TAMANOS=("4 24" "2 12" "1 6")

salida() { [ -n "${GITHUB_OUTPUT:-}" ] && echo "$1" >> "$GITHUB_OUTPUT"; }

existente=$(oci compute instance list --compartment-id "$COMP" --display-name "$NOMBRE" --all \
  --query 'data[?"lifecycle-state"!=`TERMINATED` && "lifecycle-state"!=`TERMINATING`] | [0].id' --raw-output 2>/dev/null)
if [ -n "$existente" ] && [ "$existente" != "null" ]; then
  echo "Ya existe el servidor $NOMBRE ($existente). Nada que hacer."
  salida "creado=true"
  exit 0
fi

AD=$(oci iam availability-domain list --compartment-id "$COMP" --query 'data[0].name' --raw-output)
SUBNET=$(oci network subnet list --compartment-id "$COMP" --display-name "$SUBRED" --all \
  --query 'data[0].id' --raw-output)
IMAGEN=$(oci compute image list --compartment-id "$COMP" --operating-system "Canonical Ubuntu" \
  --operating-system-version "24.04" --shape VM.Standard.A1.Flex --sort-by TIMECREATED --sort-order DESC \
  --all --query 'data[?!contains("display-name", `Minimal`)] | [0].id' --raw-output)
for v in AD SUBNET IMAGEN; do
  if [ -z "${!v}" ] || [ "${!v}" = "null" ]; then echo "No encontré $v en la cuenta."; exit 1; fi
done
echo "Zona: $AD"

llave=$(mktemp)
printf '%s\n' "$SSH_PUBLIC_KEY" > "$llave"

fin=$(( $(date +%s) + MINUTOS * 60 ))
intento=0
while [ "$(date +%s)" -lt "$fin" ]; do
  # Oracle acepta más o menos un intento por minuto: se alterna el tamaño en cada uno.
  read -r ocpus ram <<< "${TAMANOS[$(( intento % ${#TAMANOS[@]} ))]}"
  intento=$((intento + 1))
  resp=$(oci compute instance launch --no-retry \
    --availability-domain "$AD" --compartment-id "$COMP" \
    --shape VM.Standard.A1.Flex --shape-config "{\"ocpus\": $ocpus, \"memoryInGBs\": $ram}" \
    --image-id "$IMAGEN" --subnet-id "$SUBNET" --assign-public-ip true \
    --boot-volume-size-in-gbs "$DISCO_GB" --display-name "$NOMBRE" \
    --ssh-authorized-keys-file "$llave" 2>&1)
  if [ $? -eq 0 ]; then
    id=$(printf '%s' "$resp" | grep -o '"id": "ocid1.instance[^"]*"' | head -1 | cut -d'"' -f4)
    echo "¡CREADO! $ocpus OCPU / $ram GB — $id"
    salida "creado=true"
    salida "detalle=$ocpus OCPU, $ram GB de RAM, disco de $DISCO_GB GB"
    exit 0
  fi
  hora=$(date -u +%H:%M:%S)
  if grep -qiE 'out of (host )?capacity|"InternalError"' <<< "$resp"; then
    echo "$hora intento $intento: sin cupo para $ocpus OCPU / $ram GB"
  elif grep -q 'TooManyRequests' <<< "$resp"; then
    echo "$hora intento $intento: Oracle pidió bajar el ritmo; espero 2 min más"
    sleep 120
  else
    echo "$hora intento $intento: error que no es de cupo, me detengo:"
    printf '%s\n' "$resp" | grep -iE '"(code|message)"' || printf '%s\n' "$resp" | tail -5
    exit 1
  fi
  sleep "$PAUSA"
done
echo "Se acabó el tiempo de esta vuelta sin cupo. La próxima hora se intenta de nuevo."
