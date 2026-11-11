"""Refleja cada pull request en el tablero "Tareas" de monday.com.

Lo ejecuta .github/workflows/monday.yml. Por cada PR mantiene un solo elemento
(nombre "PR #<n> · <repo>: <título>") en el grupo de la fase o iteración XP según la fecha:

- abierto o listo para revisión -> "En revisión"; borrador -> "En curso";
- fusionado -> "Hecho"; cerrado sin fusionar -> "Pendiente".

Cada evento deja además un comentario en el elemento. Solo usa la biblioteca
estándar. Sin MONDAY_TOKEN termina sin error (p. ej. en forks sin el secreto).
"""

import json
import os
import sys
import urllib.request
from datetime import date, datetime, timedelta, timezone

API = "https://api.monday.com/v2"
BOGOTA = timezone(timedelta(hours=-5))

# Inicio de cada fase o iteración XP (10 mar – 16 nov 2026) -> id del grupo en el tablero
# "2. Fases, iteraciones y tareas". Después del 2 nov todo cae en Cierre.
SPRINTS = [
    (date(2026, 3, 10), "group_mm90y2q5"),  # Exploración
    (date(2026, 4, 20), "group_mm90b9j5"),  # Planificación
    (date(2026, 5, 4), "group_mm90yd5b"),  # It1
    (date(2026, 5, 18), "group_mm90geys"),  # It2
    (date(2026, 6, 1), "group_mm90sdt2"),  # It3
    (date(2026, 6, 15), "group_mm907mh4"),  # It4
    (date(2026, 6, 29), "group_mm90schc"),  # It5
    (date(2026, 7, 13), "group_mm90h2kp"),  # It6
    (date(2026, 7, 27), "group_mm90e39k"),  # It7
    (date(2026, 8, 10), "group_mm90wqfy"),  # It8
    (date(2026, 8, 24), "group_mm906s1r"),  # Producción
    (date(2026, 10, 19), "group_mm90s4pc"),  # Mantenimiento
    (date(2026, 11, 2), "group_mm90zqwx"),  # Cierre
]

# Usuario de GitHub -> (etiqueta "Responsable", id de persona en monday).
INTEGRANTES = {
    "st-alejo": ("Steven Ortega", 121692045),
    "dania2204": ("Dania Urbina", 121692376),
}

TIPO_POR_REPO = {"opaego": "Desarrollo web", "paego-mobile": "Desarrollo móvil"}


def gql(query, variables=None):
    req = urllib.request.Request(
        API,
        data=json.dumps({"query": query, "variables": variables or {}}).encode(),
        headers={
            "Authorization": os.environ["MONDAY_TOKEN"],
            "API-Version": "2025-10",
            "Content-Type": "application/json",
        },
    )
    with urllib.request.urlopen(req, timeout=30) as resp:
        cuerpo = json.load(resp)
    if cuerpo.get("errors") or cuerpo.get("error_message"):
        sys.exit(f"Error de monday: {cuerpo}")
    return cuerpo["data"]


def fecha_local(iso):
    return datetime.fromisoformat(iso.replace("Z", "+00:00")).astimezone(BOGOTA).date()


def grupo_para(dia):
    grupo = SPRINTS[0][1]
    for inicio, gid in SPRINTS:
        if dia >= inicio:
            grupo = gid
    return grupo


def estado_para(accion, pr):
    if accion == "closed":
        return "Hecho" if pr.get("merged") else "Pendiente"
    return "En curso" if pr.get("draft") else "En revisión"


def buscar_elemento(tablero, clave):
    data = gql(
        """query ($b: [ID!], $v: CompareValue!) {
             boards(ids: $b) { items_page(limit: 5, query_params: {rules: [
               {column_id: "name", compare_value: $v, operator: contains_text}]}) {
               items { id name } } } }""",
        {"b": [tablero], "v": clave},
    )
    for item in data["boards"][0]["items_page"]["items"]:
        if item["name"].startswith(clave):
            return item["id"]
    return None


def main():
    if not os.environ.get("MONDAY_TOKEN"):
        print("Sin MONDAY_TOKEN: no se sincroniza con monday.")
        return

    with open(os.environ["GITHUB_EVENT_PATH"], encoding="utf-8") as f:
        evento = json.load(f)
    accion = evento["action"]
    pr = evento["pull_request"]
    repo = evento["repository"]["name"]
    tablero = os.environ.get("MONDAY_BOARD_ID", "18439500074")

    clave = f"PR #{pr['number']} · {repo}"
    nombre = f"{clave}: {pr['title']}"[:255]
    inicio = fecha_local(pr["created_at"])
    fin = fecha_local(pr["closed_at"]) if pr.get("closed_at") else datetime.now(BOGOTA).date()
    estado = estado_para(accion, pr)

    valores = {
        "estado": {"label": estado},
        "crono": {"from": inicio.isoformat(), "to": max(fin, inicio).isoformat()},
        "github": {"url": pr["html_url"], "text": f"{repo}#{pr['number']}"},
    }

    item_id = buscar_elemento(tablero, clave)
    if item_id is None:
        autor = INTEGRANTES.get(pr["user"]["login"].lower())
        if autor:
            valores["resp"] = {"labels": [autor[0]]}
            valores["asignado"] = {"personsAndTeams": [{"id": autor[1], "kind": "person"}]}
        tipo = TIPO_POR_REPO.get(repo.lower())
        if tipo:
            valores["tipo"] = {"labels": [tipo]}
        data = gql(
            """mutation ($b: ID!, $g: String!, $n: String!, $v: JSON!) {
                 create_item(board_id: $b, group_id: $g, item_name: $n,
                             column_values: $v, create_labels_if_missing: false) { id } }""",
            {"b": tablero, "g": grupo_para(inicio), "n": nombre, "v": json.dumps(valores)},
        )
        item_id = data["create_item"]["id"]
        print(f"Elemento {item_id} creado para {clave}.")
    else:
        valores["name"] = nombre
        gql(
            """mutation ($b: ID!, $i: ID!, $v: JSON!) {
                 change_multiple_column_values(board_id: $b, item_id: $i, column_values: $v) { id } }""",
            {"b": tablero, "i": item_id, "v": json.dumps(valores)},
        )
        print(f"Elemento {item_id} actualizado para {clave}.")

    textos = {
        "opened": "abrió el PR",
        "reopened": "reabrió el PR",
        "edited": "editó el PR",
        "ready_for_review": "marcó el PR listo para revisión",
        "converted_to_draft": "pasó el PR a borrador",
        "closed": "fusionó el PR" if pr.get("merged") else "cerró el PR sin fusionar",
    }
    if accion != "edited":
        quien = evento.get("sender", {}).get("login", "alguien")
        cuerpo = (
            f"<p><b>GitHub</b>: {quien} {textos.get(accion, accion)} "
            f"<a href=\"{pr['html_url']}\">{repo}#{pr['number']}</a> "
            f"({pr['head']['ref']} → {pr['base']['ref']}). Estado: {estado}.</p>"
        )
        gql(
            "mutation ($i: ID!, $t: String!) { create_update(item_id: $i, body: $t) { id } }",
            {"i": item_id, "t": cuerpo},
        )


if __name__ == "__main__":
    main()
