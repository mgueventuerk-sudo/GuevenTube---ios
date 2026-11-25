#!/bin/sh
# Schreibt BuildSecrets.swift aus Umgebungsvariablen (GitHub Actions: Repository-Secrets).
#   YT_TV_CLIENT_ID, YT_TV_CLIENT_SECRET, YT_WEB_API_KEY
# Fehlt eine Variable, bleibt der Wert leer; die App meldet das zur Laufzeit (kein Absturz).
# Lokal danach: git update-index --assume-unchanged Packages/GuevenCore/Sources/GuevenCore/BuildSecrets.swift
set -eu
OUT="$(dirname "$0")/../Packages/GuevenCore/Sources/GuevenCore/BuildSecrets.swift"

check() { # Nur harmlose Zeichen zulassen, damit nichts in den Swift-Code eingeschleust werden kann.
  case "$2" in *[!A-Za-z0-9._-]*) echo "Fehler: $1 enthaelt unerlaubte Zeichen" >&2; exit 1;; esac
}
ID="${YT_TV_CLIENT_ID:-}"; SECRET="${YT_TV_CLIENT_SECRET:-}"; KEY="${YT_WEB_API_KEY:-}"
check YT_TV_CLIENT_ID "$ID"; check YT_TV_CLIENT_SECRET "$SECRET"; check YT_WEB_API_KEY "$KEY"
for n in ID SECRET KEY; do
  eval "v=\$$n"; [ -n "$v" ] || echo "Warnung: $n nicht gesetzt (Wert bleibt leer)" >&2
done

cat > "$OUT" <<EOF
/// Vom Build erzeugt (scripts/inject-secrets.sh). Nicht committen.
public enum BuildSecrets {
    public static let ytTvClientId = "$ID"
    public static let ytTvClientSecret = "$SECRET"
    public static let ytWebApiKey = "$KEY"
}
EOF
echo "BuildSecrets.swift geschrieben"
