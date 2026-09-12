#!/usr/bin/env bash
# Verifica que domain-scaffolder cierre el contrato de pines OpenTelemetry antes del commit (#1230).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
AGENT="$REPO_ROOT/agents/domain-scaffolder.md"

python3 - "$AGENT" <<'PY'
import re
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Optional

agente_path = Path(sys.argv[1])
agente = agente_path.read_text()
pasaron = 0
fallaron = 0


def verificar(condicion: bool, descripcion: str) -> None:
    global pasaron, fallaron
    if condicion:
        pasaron += 1
        print(f"  PASS: {descripcion}")
    else:
        fallaron += 1
        print(f"  FAIL: {descripcion}")


paquetes = {
    "OpenTelemetry.Extensions.Hosting": (
        "$REPO_ROOT/src/<RootNamespace>.{PascalCase}/<RootNamespace>.{PascalCase}.csproj",
        "produccion",
    ),
    "OpenTelemetry.Exporter.InMemory": (
        "$REPO_ROOT/tests/<RootNamespace>.{PascalCase}.Tests/<RootNamespace>.{PascalCase}.Tests.csproj",
        "tests",
    ),
}

print("[contrato] cada llamada usa el pin prescrito por su propia receta")
for paquete, (ruta_esperada, lado) in paquetes.items():
    receta = re.findall(
        rf'<PackageReference Include="{re.escape(paquete)}" Version="([^"]+)" />', agente
    )
    llamada = re.findall(
        rf'verificar_pin_otlp\s*\\\s*"{re.escape(paquete)}"\s*\\\s*'
        rf'"([^"]+)"\s*\\\s*"([^"]+)"\s*\|\|\s*exit 1',
        agente,
    )
    verificar(len(receta) == 1, f"la receta de {lado} prescribe un unico pin para {paquete}")
    verificar(len(llamada) == 1, f"Paso 7 contiene una unica llamada cerrada para {paquete}")
    verificar(
        len(receta) == 1 and len(llamada) == 1 and llamada[0][0] == receta[0],
        f"el guard de {lado} coincide con el pin de la receta",
    )
    verificar(
        len(llamada) == 1 and llamada[0][1] == ruta_esperada,
        f"el guard de {lado} apunta al csproj afectado",
    )

print("[comportamiento] el parser cuenta referencias XML, no lineas de texto")
inicio = agente.find("verificar_pin_otlp() {")
fin = agente.find("\n}\n\nverificar_pin_otlp \\", inicio)
verificar(inicio >= 0 and fin >= 0, "la funcion de verificacion puede extraerse del Paso 7")

if inicio >= 0 and fin >= 0:
    with tempfile.TemporaryDirectory() as temporal:
        raiz = Path(temporal)
        guard = raiz / "guard.sh"
        guard.write_text(agente[inicio : fin + 3])
        paquete = "OpenTelemetry.Extensions.Hosting"
        version = "1.13.1"

        def ejecutar(nombre: str, contenido: Optional[str]) -> subprocess.CompletedProcess:
            csproj = raiz / f"{nombre}.csproj"
            if contenido is not None:
                csproj.write_text(contenido)
            return subprocess.run(
                [
                    "bash",
                    "-c",
                    'source "$1"; verificar_pin_otlp "$2" "$3" "$4"',
                    "_",
                    str(guard),
                    paquete,
                    version,
                    str(csproj),
                ],
                text=True,
                capture_output=True,
                check=False,
            )

        sano = ejecutar(
            "sano",
            '<Project><ItemGroup><PackageReference Version="1.13.1"\n'
            ' Include="OpenTelemetry.Extensions.Hosting"></PackageReference></ItemGroup></Project>',
        )
        verificar(sano.returncode == 0, "acepta el unico pin exacto aunque cambie el formato XML")

        duplicado = ejecutar(
            "duplicado",
            '<Project><ItemGroup><PackageReference Include="OpenTelemetry.Extensions.Hosting" '
            'Version="1.13.1" /><PackageReference\nInclude="OpenTelemetry.Extensions.Hosting" '
            'Version="1.13.1"></PackageReference></ItemGroup></Project>',
        )
        verificar(duplicado.returncode != 0, "rechaza referencias duplicadas aunque una sea multilinea")
        verificar(
            all(valor in duplicado.stdout for valor in (paquete, version, "duplicado.csproj")),
            "el error de duplicado nombra paquete, pin y archivo",
        )

        mismatch = ejecutar(
            "mismatch",
            '<Project><ItemGroup><PackageReference Include="OpenTelemetry.Extensions.Hosting" '
            'Version="1.15.3" /></ItemGroup></Project>',
        )
        verificar(mismatch.returncode != 0, "rechaza un pin distinto")
        verificar(
            all(valor in mismatch.stdout for valor in (paquete, version, "mismatch.csproj")),
            "el error de mismatch nombra paquete, pin y archivo",
        )

        ausente = ejecutar("ausente", None)
        verificar(ausente.returncode != 0, "rechaza un csproj ausente")
        verificar(
            all(valor in ausente.stdout for valor in (paquete, version, "ausente.csproj")),
            "el error de archivo ausente nombra paquete, pin y archivo",
        )

print(f"\nRESULTADO: {pasaron} pasaron, {fallaron} fallaron")
raise SystemExit(1 if fallaron else 0)
PY
