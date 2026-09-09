#!/bin/bash
# =====================================================================
#  test-views.sh -- verifie que CHAQUE vue du resolveur repond.
#
#  Pourquoi : `named-checkconf -z` valide la syntaxe et les zones, et un
#  `dig @127.0.0.1` ne teste qu'UNE vue. Chaque vue de sous-reseau porte
#  `allow-query { <son subnet> }` : une requete venue d'ailleurs est
#  REFUSED. Sans source usurpee, 17 vues sur 19 ne sont jamais exercees.
#
#  Methode : pour chaque vue, poser une adresse du sous-reseau sur `lo`
#  et interroger avec `dig -b`. named voit alors la requete comme venant
#  de ce sous-reseau et selectionne la vue correspondante.
#
#  Usage : test-views.sh <named.conf.local> [nom_a_resoudre]
# =====================================================================
set -u
CONF=${1:?usage: test-views.sh <named.conf.local> [nom]}
NAME=${2:-registry.home.arpa}
RC=0

# --- vues et sous-reseaux, extraits de la conf elle-meme (jamais d'une
# --- liste tenue a la main : elle divergerait au premier ajout de vue).
mapfile -t VUES < <(python3 - "$CONF" <<'PY'
import re, sys, ipaddress
txt = open(sys.argv[1]).read()
for m in re.finditer(r'view\s+"([^"]+)"\s*\{\s*match-clients\s*\{([^}]*)\}', txt):
    nom, clients = m.group(1), m.group(2)
    cidrs = re.findall(r'(\d+\.\d+\.\d+\.\d+/\d+)', clients)
    if not cidrs:
        print(f"{nom}\t-")          # vue sans subnet (trusted / any)
        continue
    net = ipaddress.ip_network(cidrs[0], strict=False)
    hotes = list(net.hosts())
    print(f"{nom}\t{hotes[0] if hotes else net.network_address}")
PY
)

[ "${#VUES[@]}" -gt 0 ] || { echo "AUCUNE vue extraite de $CONF"; exit 2; }

# Sans NET_ADMIN, `ip addr add` echoue et TOUTES les vues de sous-reseau
# sortiraient en echec -- 17 faux rouges qu'on mettrait une heure a
# comprendre. On le detecte ici, une fois, et on le dit.
if ! ip addr add 203.0.113.254/32 dev lo 2>/dev/null; then
  echo "IMPOSSIBLE d'ajouter une adresse sur lo (NET_ADMIN manquant ?)." >&2
  echo "Sans ca ce test ne peut PAS interroger les vues par sous-reseau." >&2
  exit 2
fi
ip addr del 203.0.113.254/32 dev lo 2>/dev/null
echo "== ${#VUES[@]} vues declarees, $NAME interroge depuis chacune"

for ligne in "${VUES[@]}"; do
  vue=${ligne%%$'\t'*}; src=${ligne##*$'\t'}

  if [ "$src" = "-" ]; then
    # Vues sans sous-reseau. Elles ne se testent PAS toutes depuis la
    # loopback : 127.0.0.1 est dans `trusted`, donc il matche `local` en
    # premier et `internet` ne serait JAMAIS atteinte -- un vert qui ne
    # prouve rien. `internet` s'interroge donc depuis une adresse hors de
    # tout sous-reseau et hors `trusted`, sur une zone qu'elle sert.
    case "$vue" in
      internet)
        src=203.0.113.1                       # TEST-NET-3, RFC 5737
        q=jbsky.fr
        ip addr add "$src/32" dev lo 2>/dev/null
        out=$(dig -b "$src" @127.0.0.1 "$q" +short +time=3 +tries=1 2>/dev/null)
        # Controle de discrimination : cette vue ne sert PAS home.arpa et
        # tourne en `recursion no`. Une reponse ici voudrait dire qu'on est
        # tombe dans une autre vue, donc que le test ne teste rien.
        fuite=$(dig -b "$src" @127.0.0.1 "$NAME" +short +time=3 +tries=1 2>/dev/null)
        ip addr del "$src/32" dev lo 2>/dev/null
        if [ -n "$fuite" ]; then
          printf '  ECHEC  %-20s la vue repond a %s : selection de vue cassee\n' "$vue" "$NAME"
          RC=1; continue
        fi
        ;;
      *)
        src=127.0.0.1
        out=$(dig -b "$src" @127.0.0.1 jbsky.fr +short +time=3 +tries=1 2>/dev/null)
        ;;
    esac
  else
    ip addr add "$src/32" dev lo 2>/dev/null
    out=$(dig -b "$src" @127.0.0.1 "$NAME" +short +time=3 +tries=1 2>/dev/null)
    ip addr del "$src/32" dev lo 2>/dev/null
  fi

  if [ -n "$out" ]; then
    printf '  OK     %-20s depuis %-22s -> %s\n' "$vue" "$src" "$(echo "$out" | head -1)"
  else
    printf '  ECHEC  %-20s depuis %-22s -> aucune reponse\n' "$vue" "$src"
    RC=1
  fi
done

echo
[ "$RC" -eq 0 ] && echo "=== Toutes les vues resolvent ===" \
                || echo "=== Au moins une vue ne resout pas ==="
exit "$RC"
