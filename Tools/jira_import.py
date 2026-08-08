#!/usr/bin/env python3
"""Importiert Jira-Cloud-Vorgänge als Foton-Kanban-Tracks.

Zugangsdaten kommen ausschließlich aus der Umgebung — nie aus dem Repo:

    export JIRA_SITE=https://deinesite.atlassian.net
    export JIRA_EMAIL=du@example.com
    export JIRA_TOKEN=…            # https://id.atlassian.com/manage-profile/security/api-tokens
    export JIRA_CLOUD_ID=…         # optional, wird sonst selbst ermittelt

Übersicht über die eigene Jira-Struktur, bevor man importiert:

    python3 Tools/jira_import.py inspect

Probelauf, schreibt nichts:

    python3 Tools/jira_import.py import --board Beispielboard --jql 'project = FOT' --dry-run

Der Import ist wiederholbar: jeder erzeugte Track trägt seinen Jira-Schlüssel im
Frontmatter (`jira: FOT-12`). Bei einem erneuten Lauf wird genau diese Datei
aktualisiert, statt eine zweite anzulegen.
"""

from __future__ import annotations

import argparse
import base64
import json
import os
import re
import sys
import unicodedata
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

# --------------------------------------------------------------------------
# Abbildung Jira → Foton Kanban
#
# Diese Tabellen sind der Teil, den man beim ersten Mal anpasst. Alles darunter
# bleibt gleich.
# --------------------------------------------------------------------------

# Jira-Statusname (klein) → Board-Spalte. Exakte Treffer haben Vorrang vor der
# Schlagwortsuche darunter.
STATUS_MAP: dict[str, str] = {
    "backlog": "open",
    "to do": "open",
    "todo": "open",
    "offen": "open",
    # "Ready?" heißt: bereit zum Anfangen.
    "ready?": "open",
    "ready": "open",
    "in progress": "in-progress",
    "in arbeit": "in-progress",
    "done": "done",
    "fertig": "done",
    "erledigt": "done",
    "closed": "done",
}

# Schlagwörter im Statusnamen → Board-Spalte, wenn kein exakter Treffer greift.
COLUMN_KEYWORDS: list[tuple[str, str]] = [
    ("review", "review"),
    ("überprüf", "review"),
    ("abnahme", "review"),
    ("done", "done"),
    ("fertig", "done"),
    ("erledigt", "done"),
    ("closed", "done"),
    ("backlog", "open"),
    ("todo", "open"),
    ("to do", "open"),
    ("offen", "open"),
    ("idee", "open"),
]
FALLBACK_STATUS = "open"

# Schlagwörter im Statusnamen → Trackphase. Ein Status, der eine Phase benennt,
# bedeutet zugleich, dass am Track gearbeitet wird: die Spalte wird dann
# `in progress`, sofern der Name nicht zusätzlich auf Review oder Done zeigt.
PHASE_KEYWORDS: list[tuple[str, str]] = [
    ("jam", "jam-session"),
    ("arrangement", "arrangement"),
    ("arrange", "arrangement"),
    ("mixdown", "mixdown"),
    ("mixing", "mixdown"),
    ("mix", "mixdown"),
    ("fx", "fx-finalizing"),
    ("master", "mastering"),
]
FALLBACK_PHASE = "jam-session"

# Woraus das Release abgeleitet wird: "project", "epic", "fixversion" oder "none".
# Ein Jira-Projekt entspricht hier einem Release (einer EP).
RELEASE_SOURCE = "project"

# Label → Rang in der Spalte. Kleinerer Rang steht weiter oben. Tracks ohne
# eines dieser Labels landen darunter.
LABEL_PRIORITY: dict[str, int] = {"a": 0, "b": 1, "c": 2}
UNRANKED = 9

# Vorgangstypen, die als Track importiert werden. Alles andere (insbesondere
# Sub-Tasks und Epics) wird übersprungen — Sub-Tasks landen als Checkliste in
# den Notizen ihres Eltern-Vorgangs, Epics werden zu Releases.
TRACK_ISSUE_TYPES = {"story", "user story", "feature", "task", "aufgabe"}

ORDER_STEP = 1000

# --------------------------------------------------------------------------
# Jira-Zugriff
# --------------------------------------------------------------------------


class JiraError(RuntimeError):
    pass


class Jira:
    """Spricht mit Jira Cloud über `api.atlassian.com`.

    Neuere Atlassian-Tokens haben einen Geltungsbereich und werden gegen die
    Site-URL mit 401 abgelehnt — sie funktionieren nur über diesen Weg, der
    die Cloud-ID der Site braucht. Ältere Tokens funktionieren hier ebenfalls,
    deshalb gibt es nur einen Pfad.
    """

    def __init__(self, site: str, email: str, token: str, cloud_id: str | None = None) -> None:
        self.site = site.rstrip("/")
        credentials = base64.b64encode(f"{email}:{token}".encode()).decode()
        self.headers = {
            "Authorization": f"Basic {credentials}",
            "Accept": "application/json",
        }
        self.cloud_id = cloud_id or self.discover_cloud_id(self.site)
        self.base = f"https://api.atlassian.com/ex/jira/{self.cloud_id}"

    @staticmethod
    def discover_cloud_id(site: str) -> str:
        """`_edge/tenant_info` ist öffentlich und braucht keine Anmeldung."""
        try:
            with urllib.request.urlopen(f"{site}/_edge/tenant_info", timeout=30) as response:
                return json.load(response)["cloudId"]
        except Exception as error:
            raise JiraError(
                f"Cloud-ID von {site} nicht ermittelbar ({error}). "
                "Setze JIRA_CLOUD_ID von Hand."
            ) from error

    def get(self, path: str, **params: object) -> dict:
        query = urllib.parse.urlencode(
            {k: v for k, v in params.items() if v is not None}, doseq=True
        )
        url = f"{self.base}{path}" + (f"?{query}" if query else "")
        request = urllib.request.Request(url, headers=self.headers)
        try:
            with urllib.request.urlopen(request, timeout=60) as response:
                return json.load(response)
        except urllib.error.HTTPError as error:
            detail = error.read().decode("utf-8", "replace")[:400]
            if error.code == 401:
                raise JiraError(
                    "Jira lehnt die Zugangsdaten ab (401). JIRA_EMAIL muss die "
                    "Atlassian-Kontoadresse sein, und der Token muss gültig sein: "
                    "https://id.atlassian.com/manage-profile/security/api-tokens"
                ) from error
            if error.code == 403:
                raise JiraError(
                    "Jira verweigert den Zugriff (403). Das Konto darf dieses Projekt "
                    "vermutlich nicht lesen."
                ) from error
            raise JiraError(f"Jira antwortete mit HTTP {error.code}: {detail}") from error
        except urllib.error.URLError as error:
            raise JiraError(f"Jira ist nicht erreichbar: {error.reason}") from error

    def search(self, jql: str, fields: list[str]) -> list[dict]:
        """Holt alle Treffer, seitenweise."""
        issues: list[dict] = []
        token: str | None = None
        while True:
            page = self.get(
                "/rest/api/3/search/jql",
                jql=jql,
                fields=",".join(fields),
                maxResults=100,
                nextPageToken=token,
            )
            issues.extend(page.get("issues", []))
            token = page.get("nextPageToken")
            if not token or page.get("isLast", False):
                break
        return issues


# --------------------------------------------------------------------------
# Atlassian Document Format → Markdown
# --------------------------------------------------------------------------


def adf_to_markdown(node: object, depth: int = 0) -> str:
    """Wandelt die Beschreibung um. Deckt ab, was in der Praxis vorkommt;
    Unbekanntes wird auf seinen Textinhalt reduziert statt verworfen."""
    if node is None:
        return ""
    if isinstance(node, str):
        return node
    if isinstance(node, list):
        return "".join(adf_to_markdown(child, depth) for child in node)
    if not isinstance(node, dict):
        return ""

    kind = node.get("type")
    content = node.get("content", [])

    if kind == "text":
        text = node.get("text", "")
        for mark in node.get("marks", []):
            name = mark.get("type")
            if name == "strong":
                text = f"**{text}**"
            elif name == "em":
                text = f"*{text}*"
            elif name == "code":
                text = f"`{text}`"
            elif name == "strike":
                text = f"~~{text}~~"
            elif name == "link":
                href = mark.get("attrs", {}).get("href", "")
                text = f"[{text}]({href})"
        return text
    if kind == "hardBreak":
        return "\n"
    if kind == "paragraph":
        return adf_to_markdown(content, depth) + "\n\n"
    if kind == "heading":
        level = node.get("attrs", {}).get("level", 3)
        # Ab "###", damit die Überschriften nicht mit den Abschnitten der
        # Track-Datei ("## Notizen") kollidieren.
        return "#" * max(3, level + 2) + " " + adf_to_markdown(content, depth).strip() + "\n\n"
    if kind in {"bulletList", "orderedList"}:
        lines = []
        for index, item in enumerate(content, start=1):
            marker = "- " if kind == "bulletList" else f"{index}. "
            body = adf_to_markdown(item, depth + 1).strip()
            indent = "  " * depth
            first, *rest = body.split("\n") or [""]
            lines.append(f"{indent}{marker}{first}")
            lines.extend(f"{indent}  {line}" for line in rest if line.strip())
        return "\n".join(lines) + "\n\n"
    if kind == "listItem":
        return adf_to_markdown(content, depth)
    if kind == "taskList":
        lines = []
        for item in content:
            state = item.get("attrs", {}).get("state") == "DONE"
            mark = "x" if state else " "
            lines.append(f"- [{mark}] {adf_to_markdown(item.get('content', []), depth).strip()}")
        return "\n".join(lines) + "\n\n"
    if kind == "taskItem":
        return adf_to_markdown(content, depth)
    if kind == "codeBlock":
        language = node.get("attrs", {}).get("language", "")
        return f"```{language}\n{adf_to_markdown(content, depth).strip()}\n```\n\n"
    if kind == "blockquote":
        inner = adf_to_markdown(content, depth).strip().split("\n")
        return "\n".join(f"> {line}" for line in inner) + "\n\n"
    if kind == "rule":
        return "---\n\n"
    if kind in {"mediaSingle", "mediaGroup", "media"}:
        return ""
    return adf_to_markdown(content, depth)


# --------------------------------------------------------------------------
# Foton-Kanban-Dateien
# --------------------------------------------------------------------------

ID_ALPHABET = "abcdefghijkmnpqrstuvwxyz23456789"


def foton_id(jira_key: str) -> str:
    """Vierstellige ID, die für denselben Jira-Schlüssel stabil bleibt."""
    digest = 0
    for character in jira_key:
        digest = (digest * 131 + ord(character)) & 0xFFFFFFFF
    out = ""
    for _ in range(4):
        out += ID_ALPHABET[digest % len(ID_ALPHABET)]
        digest //= len(ID_ALPHABET)
    return out


def slugify(text: str) -> str:
    replacements = {"ä": "ae", "ö": "oe", "ü": "ue", "ß": "ss"}
    lowered = "".join(replacements.get(c, c) for c in text.lower())
    folded = unicodedata.normalize("NFKD", lowered).encode("ascii", "ignore").decode()
    slug = re.sub(r"[^a-z0-9]+", "-", folded).strip("-")
    return slug[:48]


def yaml_scalar(value: str) -> str:
    risky = value != value.strip() or not value
    risky = risky or value.lower() in {"true", "false", "yes", "no", "null", "~", "on", "off"}
    risky = risky or (value and value[0] in "[]{}#&*!|>%@`,\"'-?:")
    risky = risky or ": " in value or " #" in value
    if risky:
        escaped = value.replace("\\", "\\\\").replace('"', '\\"')
        return f'"{escaped}"'
    return value


def timestamp(raw: str | None) -> str:
    """Jira liefert `2026-08-02T18:40:00.000+0200`; daraus wird das Format,
    das die App schreibt."""
    if raw:
        cleaned = re.sub(r"\.\d+", "", raw)
        try:
            parsed = datetime.strptime(cleaned, "%Y-%m-%dT%H:%M:%S%z")
        except ValueError:
            return cleaned
    else:
        parsed = datetime.now(timezone.utc).astimezone()
    text = parsed.strftime("%Y-%m-%dT%H:%M:%S%z")
    return text[:-2] + ":" + text[-2:]



def render_track(track: dict) -> str:
    lines = ["---"]
    lines.append(f"id: {track['id']}")
    lines.append(f"title: {yaml_scalar(track['title'])}")
    lines.append(f"phase: {track['phase']}")
    lines.append(f"status: {track['status']}")
    if track.get("release"):
        lines.append(f"release: {yaml_scalar(track['release'])}")
    lines.append(f"order: {track['order']}")
    if track.get("review_rounds"):
        lines.append(f"review-rounds: {track['review_rounds']}")
    lines.append(f"created: {track['created']}")
    lines.append(f"updated: {track['updated']}")
    if track.get("tags"):
        lines.append("tags: [" + ", ".join(yaml_scalar(t) for t in track["tags"]) + "]")
    # Bleibt als unbekannter Schlüssel in der Datei stehen und macht den
    # Import wiederholbar. Die App trägt ihn unverändert durch.
    lines.append(f"jira: {track['jira']}")
    lines.append("---")
    lines.append("")
    lines.append("## Notizen")
    lines.append("")
    lines.append(track["notes"].strip() or f"Importiert aus {track['jira']}.")
    # Abschnitte, die in der App entstanden sind — allen voran die
    # Abhör-Checkliste — bleiben unangetastet erhalten.
    for section in track.get("kept_sections", []):
        lines.append("")
        lines.append(section.rstrip())
    return "\n".join(lines).rstrip() + "\n"


def render_release(release: dict) -> str:
    lines = ["---"]
    lines.append(f"id: {release['id']}")
    lines.append(f"title: {yaml_scalar(release['title'])}")
    if release.get("target"):
        lines.append(f"target: {release['target']}")
    lines.append(f"state: {release['state']}")
    lines.append(f"created: {release['created']}")
    lines.append(f"updated: {release['updated']}")
    lines.append("---")
    lines.append("")
    lines.append("## Notizen")
    lines.append("")
    lines.append(release.get("notes", "").strip())
    return "\n".join(lines).rstrip() + "\n"



def existing_by_jira_key(directory: Path) -> dict[str, dict]:
    """Findet Dateien aus einem früheren Lauf und liest daraus das aus, was ein
    erneuter Import nicht überschreiben darf: die Priorität innerhalb der
    Spalte, die Rundenzahl und alle Abschnitte außer den Notizen."""
    found: dict[str, dict] = {}
    if not directory.exists():
        return found

    for path in directory.glob("*.md"):
        text = path.read_text(encoding="utf-8", errors="replace")
        key_match = re.search(r"^jira:\s*(\S+)\s*$", text, re.MULTILINE)
        if not key_match:
            continue

        parts = text.split("---", 2)
        front, body = (parts[1], parts[2]) if len(parts) >= 3 else ("", text)

        order = re.search(r"^order:\s*(-?\d+)", front, re.MULTILINE)
        rounds = re.search(r"^review-rounds:\s*(\d+)", front, re.MULTILINE)
        status = re.search(r"^status:\s*(\S+)", front, re.MULTILINE)

        kept: list[str] = []
        for block in re.split(r"^## ", body, flags=re.MULTILINE)[1:]:
            heading = block.split("\n", 1)[0].strip()
            if heading.lower() != "notizen":
                kept.append("## " + block.rstrip())

        found[key_match.group(1)] = {
            "path": path,
            "order": int(order.group(1)) if order else None,
            "status": status.group(1) if status else None,
            "review_rounds": int(rounds.group(1)) if rounds else 0,
            "kept_sections": kept,
        }
    return found


# --------------------------------------------------------------------------
# Befehle
# --------------------------------------------------------------------------


def connect() -> Jira:
    missing = [k for k in ("JIRA_SITE", "JIRA_EMAIL", "JIRA_TOKEN") if not os.environ.get(k)]
    if missing:
        raise SystemExit(
            "Fehlende Umgebungsvariablen: "
            + ", ".join(missing)
            + "\nSiehe den Kopf dieser Datei."
        )
    return Jira(
        os.environ["JIRA_SITE"],
        os.environ["JIRA_EMAIL"],
        os.environ["JIRA_TOKEN"],
        os.environ.get("JIRA_CLOUD_ID"),
    )


def cmd_inspect(args: argparse.Namespace) -> None:
    jira = connect()
    me = jira.get("/rest/api/3/myself")
    print(f"Angemeldet als {me.get('displayName')} <{me.get('emailAddress')}>\n")

    projects = jira.get("/rest/api/3/project/search", maxResults=50).get("values", [])
    print(f"Projekte ({len(projects)}):")
    for project in projects:
        print(f"  {project['key']:<10} {project['name']}")

    print("\nVorgangstypen:")
    for issue_type in jira.get("/rest/api/3/issuetype"):
        flag = " (Sub-Task)" if issue_type.get("subtask") else ""
        print(f"  {issue_type['name']}{flag}")

    print("\nStatus:")
    for status in jira.get("/rest/api/3/status"):
        category = status.get("statusCategory", {}).get("name", "")
        mapped = STATUS_MAP.get(status["name"].lower(), f"→ {FALLBACK_STATUS} (Vorgabe)")
        print(f"  {status['name']:<28} [{category}]  {mapped}")

    for project in projects:
        versions = jira.get(f"/rest/api/3/project/{project['key']}/versions")
        if versions:
            print(f"\nVersionen in {project['key']}:")
            for version in versions:
                date = version.get("releaseDate", "ohne Termin")
                state = "veröffentlicht" if version.get("released") else "geplant"
                print(f"  {version['name']:<28} {date:<14} {state}")

    if projects:
        key = projects[0]["key"]
        sample = jira.search(f"project = {key} ORDER BY created DESC", ["summary", "labels"])[:5]
        print(f"\nBeispielvorgänge aus {key}:")
        for issue in sample:
            labels = ", ".join(issue["fields"].get("labels") or []) or "—"
            print(f"  {issue['key']:<10} {issue['fields']['summary'][:52]:<54} Labels: {labels}")


def cmd_import(args: argparse.Namespace) -> None:
    jira = connect()
    board = Path(args.board)
    tracks_dir = board / "tracks"
    releases_dir = board / "releases"

    fields = [
        "summary", "description", "status", "issuetype", "labels",
        "created", "updated", "parent", "project", "priority",
    ]
    issues = jira.search(args.jql, fields)
    print(f"{len(issues)} Vorgänge gefunden für: {args.jql}")

    # Sub-Tasks getrennt einsammeln, um sie den Eltern zuzuordnen.
    subtasks_by_parent: dict[str, list[dict]] = {}
    parents: list[dict] = []
    skipped: dict[str, int] = {}

    for issue in issues:
        issue_type = issue["fields"].get("issuetype") or {}
        name = issue_type.get("name", "")
        if issue_type.get("subtask"):
            parent = (issue["fields"].get("parent") or {}).get("key")
            if parent:
                subtasks_by_parent.setdefault(parent, []).append(issue)
        elif name.lower() == "epic":
            continue
        elif name.lower() in TRACK_ISSUE_TYPES or args.all_types:
            parents.append(issue)
        else:
            skipped[name] = skipped.get(name, 0) + 1

    subtask_count = sum(len(v) for v in subtasks_by_parent.values())
    print(f"  {len(parents)} als Track, {subtask_count} Sub-Tasks in die Notizen")
    for name, count in sorted(skipped.items()):
        print(f"  übersprungen: {count}× {name} (mit --all-types trotzdem importieren)")

    releases = collect_releases(parents) if RELEASE_SOURCE == "project" else {}
    existing = existing_by_jira_key(tracks_dir)

    tracks = [
        build_track(issue, subtasks_by_parent, releases, existing.get(issue["key"]))
        for issue in parents
    ]
    assign_order(tracks, existing)

    created = updated = 0
    for track in tracks:
        previous = existing.get(track["jira"])
        target = (
            previous["path"] if previous
            else tracks_dir / f"{track['id']}-{slugify(track['title'])}.md"
        )
        if previous:
            updated += 1
        else:
            created += 1

        if args.dry_run:
            release = releases_title(releases, track["release"])
            print(f"  {'akt.' if previous else 'neu ':<5} {track['title'][:34]:<36}"
                  f" {track['status']:<12} {track['phase']:<12} {release}")
        else:
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text(render_track(track), encoding="utf-8")

    for release in releases.values():
        target = releases_dir / f"{release['id']}.md"
        exists = target.exists()
        if args.dry_run:
            print(f"  {'vorh.' if exists else 'neu ':<5} Release: {release['title']}")
        elif not exists:
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text(render_release(release), encoding="utf-8")

    verb = "würden geschrieben" if args.dry_run else "geschrieben"
    print(f"\n{created} neue und {updated} aktualisierte Tracks, {len(releases)} Releases {verb}.")
    if updated and not args.dry_run:
        print("Bestehende Priorität, Rundenzahl und Abhör-Checkliste blieben erhalten.")


def releases_title(releases: dict[str, dict], release_id: str | None) -> str:
    for entry in releases.values():
        if entry["id"] == release_id:
            return entry["title"]
    return "Backlog"


def collect_releases(issues: list[dict]) -> dict[str, dict]:
    """Baut die Releases aus den Jira-Projekten.

    Ein Projekt ist hier eine EP. Projekte tragen keinen Termin — der wird in
    der Jahresplanung von Hand gesetzt. Die ID kommt aus dem Projektschlüssel
    und bleibt damit stabil, auch wenn das Projekt umbenannt wird.
    """
    releases: dict[str, dict] = {}
    for issue in issues:
        project = issue["fields"].get("project") or {}
        key = project.get("key")
        if not key or key in releases:
            continue
        now = timestamp(None)
        releases[key] = {
            "id": "r-" + slugify(key),
            "title": project.get("name") or key,
            "target": None,
            "state": "planned",
            "created": now,
            "updated": now,
            "notes": f"Importiert aus Jira-Projekt {key}. Termin in der Jahresplanung setzen.",
        }
    return releases


def derive_column_and_phase(status_name: str) -> tuple[str, str]:
    """Leitet Spalte und Phase aus dem Jira-Status ab.

    Ein Status, der eine Produktionsphase benennt ("Mixdown"), heißt: es wird
    gearbeitet. Er ergibt Spalte `in progress` plus die passende Phase. Zeigt
    der Name zusätzlich auf Review oder Done, gewinnt das für die Spalte — die
    Phase bleibt trotzdem erhalten.
    """
    lowered = status_name.lower().strip()

    phase = FALLBACK_PHASE
    phase_found = False
    for keyword, value in PHASE_KEYWORDS:
        if keyword in lowered:
            phase, phase_found = value, True
            break

    column = STATUS_MAP.get(lowered)
    if column is None:
        for keyword, value in COLUMN_KEYWORDS:
            if keyword in lowered:
                column = value
                break
    if column is None:
        column = "in-progress" if phase_found else FALLBACK_STATUS

    # Ein Status wie "Done" benennt keine Phase. Ein fertiger Track hat das
    # Mastering aber hinter sich — sonst stünde auf jeder erledigten Karte
    # "Jam Session".
    if column == "done" and not phase_found:
        phase = "mastering"

    return column, phase



def derive_column_and_phase(status_name: str) -> tuple[str, str]:
    """Leitet Spalte und Phase aus dem Jira-Status ab.

    Ein Status, der eine Produktionsphase benennt ("Mixdown"), heißt: es wird
    gearbeitet. Er ergibt Spalte `in progress` plus die passende Phase. Zeigt
    der Name zusätzlich auf Review oder Done, gewinnt das für die Spalte — die
    Phase bleibt trotzdem erhalten.
    """
    lowered = status_name.lower().strip()

    phase = FALLBACK_PHASE
    phase_found = False
    for keyword, value in PHASE_KEYWORDS:
        if keyword in lowered:
            phase, phase_found = value, True
            break

    column = STATUS_MAP.get(lowered)
    if column is None:
        for keyword, value in COLUMN_KEYWORDS:
            if keyword in lowered:
                column = value
                break
    if column is None:
        column = "in-progress" if phase_found else FALLBACK_STATUS

    # Ein Status wie "Done" benennt keine Phase. Ein fertiger Track hat das
    # Mastering aber hinter sich — sonst stünde auf jeder erledigten Karte
    # "Jam Session".
    if column == "done" and not phase_found:
        phase = "mastering"

    return column, phase


def label_rank(labels: list[str]) -> int:
    """A vor B vor C, alles andere darunter."""
    ranks = [LABEL_PRIORITY[l.lower()] for l in labels if l.lower() in LABEL_PRIORITY]
    return min(ranks) if ranks else UNRANKED


def build_track(
    issue: dict,
    subtasks_by_parent: dict[str, list[dict]],
    releases: dict[str, dict],
    previous: dict | None = None,
) -> dict:
    fields = issue["fields"]
    key = issue["key"]

    status, phase = derive_column_and_phase((fields.get("status") or {}).get("name", ""))

    project_key = (fields.get("project") or {}).get("key")
    release_id = releases.get(project_key, {}).get("id") if project_key else None

    notes = adf_to_markdown(fields.get("description")).strip()
    subtasks = subtasks_by_parent.get(key, [])
    if subtasks:
        lines = ["", "### Aufgaben aus Jira", ""]
        for subtask in subtasks:
            done = (subtask["fields"].get("status") or {}).get(
                "statusCategory", {}
            ).get("key") == "done"
            lines.append(f"- [{'x' if done else ' '}] {subtask['fields']['summary']}")
        notes = (notes + "\n" + "\n".join(lines)).strip()

    labels = list(fields.get("labels") or [])

    return {
        "id": foton_id(key),
        "title": fields.get("summary", key),
        "phase": phase,
        "status": status,
        "release": release_id,
        # Wird erst vergeben, wenn alle Tracks bekannt sind — die Priorität
        # ergibt sich aus dem Vergleich innerhalb der Spalte.
        "order": previous["order"] if previous and previous.get("order") is not None else None,
        "rank": label_rank(labels),
        "review_rounds": (previous or {}).get("review_rounds", 0),
        "created": timestamp(fields.get("created")),
        "updated": timestamp(fields.get("updated")),
        # A/B/C sind Priorität und keine Schlagworte — sie landen in der
        # Reihenfolge, nicht in den Tags.
        "tags": [l for l in labels if l.lower() not in LABEL_PRIORITY],
        "notes": notes,
        "kept_sections": (previous or {}).get("kept_sections", []),
        "jira": key,
    }


def assign_order(tracks: list[dict], existing: dict[str, dict]) -> None:
    """Vergibt die Priorität innerhalb jeder Spalte.

    Bereits importierte Tracks behalten ihren Platz. Neue werden nach Label
    einsortiert — A oben — und hinter dem angehängt, was in der Spalte schon
    liegt.
    """
    highest: dict[str, int] = {}
    for entry in existing.values():
        if entry["status"] and entry["order"] is not None:
            highest[entry["status"]] = max(highest.get(entry["status"], 0), entry["order"])

    by_status: dict[str, list[dict]] = {}
    for track in tracks:
        if track["order"] is None:
            by_status.setdefault(track["status"], []).append(track)

    for status, group in by_status.items():
        group.sort(key=lambda t: (t["rank"], t["jira"]))
        value = highest.get(status, 0)
        for track in group:
            value += ORDER_STEP
            track["order"] = value


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest="command", required=True)

    commands.add_parser("inspect", help="Projekte, Status, Versionen und Labels anzeigen")

    importer = commands.add_parser("import", help="Vorgänge als Tracks schreiben")
    importer.add_argument("--board", required=True, help="Ordner des Foton-Boards")
    importer.add_argument("--jql", required=True, help="JQL, z. B. 'project = FOT'")
    importer.add_argument("--dry-run", action="store_true", help="nur anzeigen, nichts schreiben")
    importer.add_argument("--all-types", action="store_true",
                          help="alle Vorgangstypen als Track importieren")
    importer.add_argument("--overwrite-releases", action="store_true",
                          help="bestehende Release-Dateien überschreiben")

    args = parser.parse_args()
    try:
        if args.command == "inspect":
            cmd_inspect(args)
        else:
            cmd_import(args)
    except JiraError as error:
        print(f"Fehler: {error}", file=sys.stderr)
        raise SystemExit(1)


if __name__ == "__main__":
    main()
