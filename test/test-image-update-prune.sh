#!/bin/bash
# =====================================================================
#  test-image-update-prune.sh — banc de la selection « quoi purger »
#  d'image-update.yaml (tache « prune — choisir les images a supprimer »)
#
#  Il EXTRAIT la tache du playbook reel et la joue sur localhost avec la
#  sortie fabriquee de `show container image json`, qui porte UNE ENTREE PAR
#  TAG (une image a trois tags apparait trois fois, memes id et memes noms).
#
#  Ce qu'il verrouille (run 1366, 2026-11-11 : 26 images annoncees, aucune
#  de celles a plusieurs tags supprimee) :
#    - chaque image n'apparait qu'UNE fois dans la liste a purger ;
#    - la suppression se fait par NOM, un par tag (`podman image rm <id>`
#      refuse une image multi-tags, l'op-mode n'expose pas --force) ;
#    - une image sans nom se supprime par son identifiant ;
#    - une image designee par la config, ou portee par un conteneur, reste.
#
#  Usage : test/test-image-update-prune.sh      Sort 0 si tout passe.
# =====================================================================
set -euo pipefail
cd "$(dirname "$0")/.."

BANC=$(mktemp -d); trap 'rm -rf "$BANC"' EXIT

python3 - "$BANC" <<'PY'
import sys, yaml, json
banc = sys.argv[1]
nom = "prune — choisir les images a supprimer"
jeu = yaml.safe_load(open('image-update.yaml', encoding='utf-8'))[0]
taches = [t for t in jeu['tasks'] if t.get('name') == nom]
assert len(taches) == 1, f"tache « {nom} » introuvable dans image-update.yaml"
tache = taches[0]
tache.pop('tags', None)
yaml.safe_dump([tache], open(f'{banc}/tache.yaml', 'w', encoding='utf-8'),
               allow_unicode=True, default_flow_style=False, sort_keys=False)

P = 'docker.io/jbsky/'
def entree(i, noms, conteneurs=0):
    return {'id': i, 'names': [P + n for n in noms], 'repo_digests': [], 'containers': conteneurs, 'size': 1000000}

# Une entree PAR TAG, comme le fait `show container image json`.
multi = ['clamav-hardened:1.5.4.22', 'clamav-hardened:1.5.4.21']
images = (
    [entree('aaa111', multi)] * 2 +                              # multi-tags : 2 entrees
    [entree('bbb222', ['squid-hardened:7.7.20', 'squid-hardened:7.7.19', 'squid-hardened:7.7.18'])] * 3 +
    [entree('ccc333', ['bind9-hardened:9.20.30.4'])] +           # un seul tag
    [entree('ddd444', ['bind9-hardened:9.20.30.6'])] +           # designee par la config
    [entree('eee555', ['haproxy-hardened:3.4.6.9'], conteneurs=1)] +  # porte par un conteneur
    [entree('fff666', [])]                                       # sans nom
)
config = "\n".join([
    f"set container name bind9 image '{P}bind9-hardened:9.20.30.6'",
    f"set container name haproxy image '{P}haproxy-hardened:3.4.6.9'",
])
play = [{
    'name': 'purge : une entree par image, cibles par nom',
    'hosts': 'localhost', 'connection': 'local', 'gather_facts': False,
    'vars': {'_prune_lecture': {'results': [{'stdout': config}, {'stdout': json.dumps(images)}]}},
    'tasks': [
        {'ansible.builtin.import_tasks': f'{banc}/tache.yaml'},
        {'name': 'chaque image une seule fois',
         'ansible.builtin.assert': {
             'that': ["(_a_purger | map(attribute='id') | list | sort) == ['aaa111', 'bbb222', 'ccc333', 'fff666']"],
             'fail_msg': "ids : {{ _a_purger | map(attribute='id') | list | to_json }}", 'quiet': True}},
        {'name': 'suppression par nom, un appel par tag ; l image sans nom par id',
         'ansible.builtin.assert': {
             'that': ["(_a_purger | map(attribute='cibles') | flatten | unique | list | sort) == "
                      "['" + P + "bind9-hardened:9.20.30.4', '" + P + "clamav-hardened:1.5.4.21', '" + P + "clamav-hardened:1.5.4.22', "
                      "'" + P + "squid-hardened:7.7.18', '" + P + "squid-hardened:7.7.19', '" + P + "squid-hardened:7.7.20', 'fff666']"],
             'fail_msg': "cibles : {{ _a_purger | map(attribute='cibles') | list | to_json }}", 'quiet': True}},
    ],
}]
yaml.safe_dump(play, open(f'{banc}/banc.yaml', 'w', encoding='utf-8'),
               allow_unicode=True, default_flow_style=False, sort_keys=False)
PY

printf '[defaults]\nlocalhost_warning=False\n' > "$BANC/ansible.cfg"
ANSIBLE_CONFIG="$BANC/ansible.cfg" ANSIBLE_INVENTORY_UNPARSED_WARNING=False \
  ansible-playbook -i localhost, "$BANC/banc.yaml"
