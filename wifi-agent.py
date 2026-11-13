#!/usr/bin/python3
"""Authenticated, Unix-socket-only bridge to the Pi's NetworkManager."""
import configparser
import json
import os
from pathlib import Path
import socketserver
import subprocess
import threading
import uuid
from http.server import BaseHTTPRequestHandler

import jwt

INTERFACE = os.environ.get('WIFI_INTERFACE', 'wlan0')
KEY = (Path(os.environ.get('TCG_POS_DIR', '/opt/tcg-pos')) / 'secrets/simple-pos-jwt-public.pem').read_text()
LOCK = threading.Lock()


def nm(*args, timeout=20):
    result = subprocess.run(['nmcli', *args], capture_output=True, text=True,
                            timeout=timeout, check=True)
    return result.stdout.strip()


def status():
    state = nm('-g', 'GENERAL.STATE', 'device', 'show', INTERFACE)
    addresses = nm('-g', 'IP4.ADDRESS', 'device', 'show', INTERFACE).splitlines()
    connection = nm('-g', 'GENERAL.CON-UUID', 'device', 'show', INTERFACE)
    ssid = None
    if state.startswith('100') and connection and connection != '--':
        ssid = nm('-g', '802-11-wireless.ssid', 'connection', 'show', 'uuid', connection)
    return {'state': state, 'addresses': [x.split('/')[0] for x in addresses if x],
            'ssid': ssid, 'hostname': os.uname().nodename + '.local'}


def connect(ssid, password):
    if not isinstance(ssid, str) or not 1 <= len(ssid.encode()) <= 32 or '\x00' in ssid:
        raise ValueError('Enter a Wi-Fi name of 1–32 bytes.')
    if not isinstance(password, str) or not 8 <= len(password) <= 63 or any(c in password for c in '\r\n\x00'):
        raise ValueError('Enter a WPA/WPA2 personal password of 8–63 characters.')
    identifier = str(uuid.uuid4())
    path = Path('/etc/NetworkManager/system-connections') / f'tcg-pos-{identifier}.nmconnection'
    config = configparser.ConfigParser(interpolation=None)
    config['connection'] = {'id': 'TCG POS Wi-Fi', 'uuid': identifier, 'type': 'wifi',
                            'interface-name': INTERFACE, 'autoconnect': 'true'}
    config['wifi'] = {'mode': 'infrastructure', 'ssid': ';'.join(str(b) for b in ssid.encode()) + ';', 'hidden': 'true'}
    # GLib keyfile escaping preserves backslashes, whitespace and tabs in PSKs.
    escaped_password = password.replace('\\', '\\\\').replace(' ', '\\s').replace('\t', '\\t')
    config['wifi-security'] = {'key-mgmt': 'wpa-psk', 'psk': escaped_password}
    config['ipv4'] = {'method': 'auto'}
    config['ipv6'] = {'method': 'auto'}
    previous = nm('-g', 'GENERAL.CON-UUID', 'device', 'show', INTERFACE)
    try:
        with open(path, 'x', opener=lambda p, flags: os.open(p, flags, 0o600)) as stream:
            config.write(stream, space_around_delimiters=False)
        nm('connection', 'load', str(path))
        nm('--wait', '45', 'connection', 'up', 'uuid', identifier, 'ifname', INTERFACE, timeout=55)
        result = status()
        if not result['addresses']:
            raise ValueError('Wi-Fi did not receive an IPv4 address. Keep Ethernet connected.')
        return result
    except Exception:
        try:
            nm('connection', 'delete', 'uuid', identifier)
        except (subprocess.SubprocessError, OSError):
            pass
        path.unlink(missing_ok=True)
        if previous and previous != '--':
            try:
                nm('--wait', '15', 'connection', 'up', 'uuid', previous, 'ifname', INTERFACE, timeout=20)
            except (subprocess.SubprocessError, OSError):
                pass
        raise


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass  # Never log tokens, request bodies, or Wi-Fi credentials.

    def reply(self, code, body):
        data = json.dumps(body).encode()
        self.send_response(code)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Cache-Control', 'no-store')
        self.send_header('Content-Length', str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def handle_request(self):
        self.connection.settimeout(15)
        try:
            auth = self.headers.get('Authorization', '')
            if not auth.startswith('Bearer '):
                return self.reply(401, {'error': 'Sign in again.'})
            claims = jwt.decode(auth[7:], KEY, algorithms=['RS256'],
                                issuer=os.environ.get('JWT_ISSUER', 'simple-pos-api'),
                                audience=os.environ.get('JWT_AUDIENCE', 'simple-pos-app'),
                                options={'require': ['exp', 'sub', 'nbf', 'shop_id', 'shop_role']})
            if claims['shop_role'] != 'ADMIN':
                return self.reply(403, {'error': 'POS admin access required.'})
            if self.headers.get('X-POS-Wifi') != '1':
                return self.reply(403, {'error': 'Invalid request.'})
            if self.path not in ('/device/wifi/status', '/device/wifi/networks', '/device/wifi/connect'):
                return self.reply(404, {'error': 'Unknown operation.'})
            if not LOCK.acquire(blocking=False):
                return self.reply(409, {'error': 'Wi-Fi is busy. Wait and try again.'})
            try:
                if self.command == 'GET' and self.path.endswith('/status'):
                    return self.reply(200, status())
                if self.command == 'GET' and self.path.endswith('/networks'):
                    rows = nm('-t', '--escape', 'no', '-f', 'SSID,SIGNAL,SECURITY', 'device', 'wifi', 'list', 'ifname', INTERFACE, '--rescan', 'yes').splitlines()
                    networks = {}
                    for row in rows:
                        name, signal, security = row.rsplit(':', 2)
                        if name and name not in networks:
                            networks[name] = {'ssid': name, 'signal': signal, 'security': security}
                    return self.reply(200, {'networks': list(networks.values())})
                if self.command == 'POST' and self.path.endswith('/connect'):
                    size = int(self.headers.get('Content-Length', '0'))
                    if not 1 <= size <= 4096:
                        return self.reply(400, {'error': 'Invalid request size.'})
                    if self.headers.get('Content-Type', '').split(';')[0] != 'application/json':
                        return self.reply(400, {'error': 'JSON required.'})
                    data = json.loads(self.rfile.read(size))
                    return self.reply(200, connect(data.get('ssid'), data.get('password')))
                return self.reply(405, {'error': 'Unsupported operation.'})
            finally:
                LOCK.release()
        except jwt.InvalidTokenError:
            self.reply(401, {'error': 'Sign in again.'})
        except (ValueError, TypeError, AttributeError):
            self.reply(400, {'error': 'Check the network name and password (WPA/WPA2 personal, 8–63 characters).'})
        except (subprocess.SubprocessError, OSError):
            self.reply(503, {'error': 'Could not configure Wi-Fi. Check password, radio/country settings and signal. Keep Ethernet connected.'})

    do_GET = handle_request
    do_POST = handle_request


class Server(socketserver.ThreadingMixIn, socketserver.UnixStreamServer):
    daemon_threads = True


if __name__ == '__main__':
    socket_path = '/run/tcg-pos-wifi/control.sock'
    Path(socket_path).unlink(missing_ok=True)
    with Server(socket_path, Handler) as server:
        os.chmod(socket_path, 0o666)  # Access also requires a verified ADMIN JWT.
        server.serve_forever()
