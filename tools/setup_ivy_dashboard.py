"""Creates the "Ivy" dashboard (/ivy-app) that configures the Flutter app on the Lenovo.

Usage:  python tools/setup_ivy_dashboard.py [--force]   (reads ../secrets.json)
The entity ids below are examples: replace them with your own.
Each view is a tab of the app (in order). Paths inicio/casa/multimedia/reloj keep
their native pages (Inicio takes its people, vacuum, camera, scenes/scripts and
calendars from its cards); any other path is drawn generically from its entities.
Edit it afterwards in HA (Ajustes > Paneles > Ivy): the app reloads on save.
Without --force an existing dashboard config is left untouched.
"""
import asyncio
import json
import pathlib
import sys

import websockets

SECRETS = json.load(open(pathlib.Path(__file__).parent.parent / 'secrets.json', encoding='utf-8'))
BASE = 'https://' + SECRETS['HA_HOST']
TOKEN = SECRETS['HA_TOKEN']
URL_PATH = 'ivy-app'  # must match ivyDashboard in lib/ha.dart

CONFIG = {
    'title': 'Ivy',
    'views': [
        {'title': 'Inicio', 'path': 'inicio', 'cards': [
            {'type': 'tile', 'entity': 'person.alex', 'name': 'Alex'},
            {'type': 'tile', 'entity': 'person.sam', 'name': 'Sam'},
            {'type': 'tile', 'entity': 'vacuum.roborock_q10_vf', 'name': 'Roborock'},
            {'type': 'picture-entity', 'entity': 'camera.entryway_entryway', 'name': 'Timbre entrada'},
            {'type': 'entities', 'title': 'Accesos rápidos', 'entities': [
                {'entity': 'scene.despertar', 'name': 'Despertar', 'icon': 'mdi:weather-sunset-up'},
                {'entity': 'scene.sleeping', 'name': 'Dormir', 'icon': 'mdi:sleep'},
                {'entity': 'script.home_arrive', 'name': 'Llego a casa', 'icon': 'mdi:home'},
                {'entity': 'script.home_leave', 'name': 'Me voy', 'icon': 'mdi:walk'},
            ]},
            {'type': 'calendar', 'entities': [
                {'entity': 'calendar.familia', 'name': 'Familia'},
                {'entity': 'calendar.cumpleanos', 'name': 'Cumpleaños'},
                {'entity': 'calendar.festivos_en_espana', 'name': 'Festivos'},
                {'entity': 'calendar.personal', 'name': 'Personal'},
            ]},
        ]},
        {'title': 'Casa', 'path': 'casa', 'cards': [
            {'type': 'markdown', 'content': 'Página nativa: muestra las áreas de Home Assistant.'}]},
        {'title': 'Roborock', 'path': 'roborock', 'cards': [
            {'type': 'picture-entity', 'entity': 'image.roborock_q10_vf_mapa', 'name': 'Mapa'},
            {'type': 'tile', 'entity': 'vacuum.roborock_q10_vf', 'name': 'Roborock'},
            {'type': 'entities', 'entities': [
                {'entity': 'sensor.roborock_q10_vf_estado', 'name': 'Estado'},
                {'entity': 'sensor.roborock_q10_vf_bateria', 'name': 'Batería'},
                {'entity': 'select.roborock_q10_vf_modo_de_limpieza', 'name': 'Modo'},
                {'entity': 'sensor.roborock_q10_vf_progreso_de_la_limpieza', 'name': 'Progreso'},
                {'entity': 'sensor.roborock_q10_vf_area_de_limpieza', 'name': 'Área limpiada'},
                {'entity': 'switch.roborock_q10_vf_no_molestar', 'name': 'No molestar'},
                {'entity': 'button.roborock_q10_vf_vaciar_el_deposito_de_suciedad', 'name': 'Vaciar depósito'},
            ]},
        ]},
        {'title': 'Luz', 'path': 'luz', 'cards': [  # any view with sensor.edata_* -> lib/energy.dart
            {'type': 'tile', 'entity': 'sensor.edata_xxxx', 'name': 'Luz'}]},
        {'title': 'Cámaras', 'path': 'camaras', 'cards': [  # empty = every HA camera; list cameras to choose
            {'type': 'markdown', 'content': 'Página nativa: todas las cámaras de Home Assistant.'}]},
        {'title': 'Paquetes', 'path': 'paquetes', 'cards': [
            {'type': 'markdown', 'content': 'Página nativa: paquetes de 17track.'}]},
        {'title': 'Impresora', 'path': 'impresora', 'cards': [  # generic view: Moonraker camera + tiles
            {'type': 'picture-entity', 'entity': 'camera.ender_3_v3_ke_nebulacamera',
             'name': 'Ender 3 V3 KE', 'camera_view': 'live'},
            {'type': 'entities', 'entities': [
                {'entity': 'sensor.ender_3_v3_ke_current_print_state', 'name': 'Estado'},
                {'entity': 'sensor.ender_3_v3_ke_progress', 'name': 'Progreso'},
                {'entity': 'sensor.ender_3_v3_ke_print_eta', 'name': 'Termina'},
                {'entity': 'sensor.ender_3_v3_ke_current_layer', 'name': 'Capa'},
                {'entity': 'sensor.ender_3_v3_ke_extruder_temperature', 'name': 'Extrusor'},
                {'entity': 'sensor.ender_3_v3_ke_bed_temperature', 'name': 'Cama'},
                {'entity': 'sensor.ender_3_v3_ke_filename', 'name': 'Archivo'},
                {'entity': 'binary_sensor.ender_3_v3_ke_filament_sensor', 'name': 'Filamento'},
                {'entity': 'button.ender_3_v3_ke_pause_print', 'name': 'Pausar'},
                {'entity': 'button.ender_3_v3_ke_resume_print', 'name': 'Reanudar'},
            ]},
        ]},
        {'title': 'Multimedia', 'path': 'multimedia', 'cards': [
            {'type': 'markdown', 'content': 'Página nativa: reproductores y Spotify.'}]},
        {'title': 'Reloj', 'path': 'reloj', 'cards': [
            {'type': 'markdown', 'content': 'Página nativa: alarmas y temporizadores.'}]},
    ],
}


async def main(force):
    async with websockets.connect(BASE.replace('https', 'wss') + '/api/websocket', max_size=None) as ws:
        await ws.recv()
        await ws.send(json.dumps({'type': 'auth', 'access_token': TOKEN}))
        await ws.recv()
        n = 0

        async def call(msg):
            nonlocal n
            n += 1
            await ws.send(json.dumps({'id': n, **msg}))
            while True:
                r = json.loads(await ws.recv())
                if r.get('id') == n:
                    return r

        dashboards = (await call({'type': 'lovelace/dashboards/list'}))['result']
        if not any(d['url_path'] == URL_PATH for d in dashboards):
            r = await call({'type': 'lovelace/dashboards/create', 'url_path': URL_PATH, 'title': 'Ivy',
                            'icon': 'mdi:tablet-dashboard', 'mode': 'storage',
                            'require_admin': True, 'show_in_sidebar': True})
            print('dashboard created' if r['success'] else r)
        existing = await call({'type': 'lovelace/config', 'url_path': URL_PATH})
        if existing['success'] and not force:
            print('config already exists; use --force to overwrite')
            return
        r = await call({'type': 'lovelace/config/save', 'url_path': URL_PATH, 'config': CONFIG})
        print('config saved' if r['success'] else r)


asyncio.run(main('--force' in sys.argv))
