#!/bin/bash
# =====================================================================
#  test-image-update-redemarrage.sh — banc de la selection « qui redemarre »
#  d'image-update.yaml (tache « apply — conteneurs a redemarrer ou a verifier »)
#
#  Il EXTRAIT la tache du playbook reel (pas une copie : une copie derive) et
#  la joue sur localhost avec des entrees fabriquees, puis compare la liste
#  obtenue a la liste attendue. Il ne touche a aucun routeur.
#
#  Pourquoi : depuis les unites quadlet, le commit de VyOS redemarre deja par
#  systemd chaque conteneur dont la config change. Ce playbook ne redemarre
#  donc plus que les cas ou le commit ne l'a pas fait -- une regle a trois
#  branches qu'on ne peut pas verifier a l'oeil.
#
#  Usage : test/test-image-update-redemarrage.sh
#  Sort 0 si les six cas passent, 1 sinon.
# =====================================================================
set -euo pipefail
cd "$(dirname "$0")/.."

BANC=$(mktemp -d); trap 'rm -rf "$BANC"' EXIT

python3 - "$BANC" <<'PY'
import sys, yaml
banc = sys.argv[1]
nom = "apply — conteneurs a redemarrer ou a verifier"
jeu = yaml.safe_load(open('image-update.yaml', encoding='utf-8'))[0]
taches = [t for t in jeu['tasks'] if t.get('name') == nom]
assert len(taches) == 1, f"tache « {nom} » introuvable dans image-update.yaml"
tache = taches[0]
tache.pop('when', None)          # le banc n'est jamais en check_mode
tache.pop('tags', None)
yaml.safe_dump([tache], open(f'{banc}/tache.yaml', 'w', encoding='utf-8'),
               allow_unicode=True, default_flow_style=False, sort_keys=False)

# Le tableau de lecture seule du homelab, reduit : l'ordre est ce qu'on teste.
table = [{'name': 'clamav'}, {'name': 'c-icap'}, {'name': 'squid'}, {'name': 'bind9'}]
routeur = ['bind9', 'squid', 'c-icap', 'clamav', 'haproxy']   # haproxy hors tableau
chg = lambda *n: [{'nom': x, 'voulue': f'docker.io/jbsky/{x}:1.2.3'} for x in n]

cas = [
    # libelle, entrees, attendu [(nom, restart, image)]
    ("montee d'image, reglage en place",
     dict(_ro_actif=True, _dropin=True, _retire=False, _a_changer=chg('squid', 'bind9'),
          _ro_a_poser=[], force_restart=False),
     [('squid', False, 'docker.io/jbsky/squid:1.2.3'),
      ('bind9', False, 'docker.io/jbsky/bind9:1.2.3')]),

    ("bascule : pose du reglage global",
     dict(_ro_actif=True, _dropin=False, _retire=False, _a_changer=chg('squid'),
          _ro_a_poser=[], force_restart=False),
     [('clamav', True, ''), ('c-icap', True, ''), ('squid', True, 'docker.io/jbsky/squid:1.2.3'),
      ('bind9', True, ''), ('haproxy', True, '')]),

    ("bascule : retrait du reglage global",
     dict(_ro_actif=False, _dropin=True, _retire=True, _a_changer=[],
          _ro_a_poser=[], force_restart=False),
     [('clamav', True, ''), ('c-icap', True, ''), ('squid', True, ''),
      ('bind9', True, ''), ('haproxy', True, '')]),

    ("rien a faire : ni image ni ligne ni bascule",
     dict(_ro_actif=True, _dropin=True, _retire=False, _a_changer=[],
          _ro_a_poser=[], force_restart=False),
     []),

    ("lignes tmpfs posees par le commit",
     dict(_ro_actif=True, _dropin=True, _retire=False, _a_changer=chg('squid'),
          _ro_a_poser=[{'nom': 'clamav', 'ligne': "set container name clamav uid '4000'"}],
          force_restart=False),
     [('clamav', False, ''), ('squid', False, 'docker.io/jbsky/squid:1.2.3')]),

    ("force_restart=true (filet)",
     dict(_ro_actif=True, _dropin=True, _retire=False, _a_changer=chg('squid', 'haproxy'),
          _ro_a_poser=[], force_restart=True),
     [('squid', True, 'docker.io/jbsky/squid:1.2.3'), ('haproxy', True, 'docker.io/jbsky/haproxy:1.2.3')]),
]

plays = []
for i, (libelle, e, attendu) in enumerate(cas):
    plays.append({
        'name': f"cas {i + 1} : {libelle}",
        'hosts': 'localhost',
        'connection': 'local',
        'gather_facts': False,
        'vars': {
            '_ro_actif': e['_ro_actif'],
            '_ro_dropin_stat': {'stat': {'exists': e['_dropin']}},
            '_ro_retire': {'changed': e['_retire'], 'failed': False},
            '_ro_routeur': routeur,
            '_ro_table': table,
            '_ro_noms_table': [c['name'] for c in table],
            '_a_changer': e['_a_changer'],
            '_ro_a_poser': e['_ro_a_poser'],
            'force_restart': e['force_restart'],
            '_attendu': [{'name': n, 'restart': r, 'image': im} for n, r, im in attendu],
        },
        'tasks': [
            {'ansible.builtin.import_tasks': f'{banc}/tache.yaml'},
            {'name': 'obtenu == attendu, dans le meme ORDRE',
             'ansible.builtin.assert': {
                 'that': ["(_a_redemarrer | map(attribute='name') | list) == (_attendu | map(attribute='name') | list)",
                          "(_a_redemarrer | map(attribute='restart') | map('bool') | list) == (_attendu | map(attribute='restart') | list)",
                          "(_a_redemarrer | map(attribute='image') | list) == (_attendu | map(attribute='image') | list)"],
                 'fail_msg': "obtenu {{ _a_redemarrer | to_json }}\nattendu {{ _attendu | to_json }}",
                 'success_msg': "{{ _a_redemarrer | map(attribute='name') | zip(_a_redemarrer | map(attribute='restart')) | list | to_json }}",
                 'quiet': True}},
        ],
    })
yaml.safe_dump(plays, open(f'{banc}/banc.yaml', 'w', encoding='utf-8'),
               allow_unicode=True, default_flow_style=False, sort_keys=False)
print(f"banc : {len(plays)} cas")
PY

# Config vide : le banc ne doit herite ni du vault ni de l'inventaire du
# depot privé qui embarque ce playbook en sous-module.
printf '[defaults]\nlocalhost_warning=False\n' > "$BANC/ansible.cfg"
ANSIBLE_CONFIG="$BANC/ansible.cfg" ANSIBLE_INVENTORY_UNPARSED_WARNING=False \
  ansible-playbook -i localhost, "$BANC/banc.yaml"
