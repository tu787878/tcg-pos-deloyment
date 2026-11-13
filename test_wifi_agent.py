"""Host-agent tests without changing any network settings or requiring PyJWT."""
import importlib.util
from pathlib import Path
import subprocess
import socketserver
import sys
import tempfile
import types
import unittest
from unittest.mock import Mock, patch

fake_jwt = types.SimpleNamespace(InvalidTokenError=type('InvalidTokenError', (Exception,), {}), decode=Mock())
spec = importlib.util.spec_from_file_location('wifi_agent', Path(__file__).with_name('wifi-agent.py'))
agent = importlib.util.module_from_spec(spec)
with patch.dict(sys.modules, {'jwt': fake_jwt}), patch.object(Path, 'read_text', return_value='test-key'), patch.object(socketserver, 'UnixStreamServer', getattr(socketserver, 'UnixStreamServer', socketserver.TCPServer), create=True):
    spec.loader.exec_module(agent)


class AgentTests(unittest.TestCase):
    def test_invalid_credentials_do_not_run_commands(self):
        with patch.object(agent, 'nm') as nm:
            for ssid, password in [('', 'password'), ('x' * 33, 'password'), ('Shop', 'short'), ('Shop', 'password\nsecret')]:
                with self.assertRaises(ValueError):
                    agent.connect(ssid, password)
            nm.assert_not_called()

    def test_success_stores_secret_only_in_private_profile(self):
        with tempfile.TemporaryDirectory() as directory, patch.object(agent, 'Path', return_value=Path(directory)), patch.object(agent, 'nm', return_value='--') as nm, patch.object(agent, 'status', return_value={'addresses': ['192.168.0.50']}):
            agent.connect('Shop: WiFi', 'secret-password')
            profile = next(Path(directory).iterdir())
            self.assertIn('psk=secret-password', profile.read_text())
            self.assertIn('autoconnect=true', profile.read_text())
            self.assertNotIn('secret-password', repr(nm.call_args_list))

    def test_failure_removes_new_profile_and_restores_previous(self):
        calls = []
        def nm(*args, **_):
            calls.append(args)
            if args[:2] == ('-g', 'GENERAL.CON-UUID'):
                return 'previous-uuid'
            if 'up' in args and 'previous-uuid' not in args:
                raise subprocess.CalledProcessError(1, 'nmcli')
            return ''
        with tempfile.TemporaryDirectory() as directory, patch.object(agent, 'Path', return_value=Path(directory)), patch.object(agent, 'nm', side_effect=nm):
            with self.assertRaises(subprocess.CalledProcessError):
                agent.connect('Shop', 'wrong-password')
            self.assertEqual(list(Path(directory).iterdir()), [])
            self.assertTrue(any('previous-uuid' in call and 'up' in call for call in calls))

    def test_password_whitespace_and_backslash_are_escaped(self):
        with tempfile.TemporaryDirectory() as directory, patch.object(agent, 'Path', return_value=Path(directory)), patch.object(agent, 'nm', return_value='--'), patch.object(agent, 'status', return_value={'addresses': ['192.168.0.50']}):
            agent.connect('Shop', ' secret\\pass ')
            profile = next(Path(directory).iterdir()).read_text()
            self.assertIn(r'psk=\ssecret\\pass\s', profile)

    def test_missing_address_rolls_back(self):
        with tempfile.TemporaryDirectory() as directory, patch.object(agent, 'Path', return_value=Path(directory)), patch.object(agent, 'nm', return_value='--') as nm, patch.object(agent, 'status', return_value={'addresses': []}):
            with self.assertRaises(ValueError):
                agent.connect('Shop', 'secret-password')
            self.assertEqual(list(Path(directory).iterdir()), [])
            self.assertTrue(any('delete' in call.args for call in nm.call_args_list))

    def handler(self, auth='Bearer token'):
        handler = object.__new__(agent.Handler)
        handler.headers = {'Authorization': auth, 'X-POS-Wifi': '1'}
        handler.path = '/device/wifi/status'
        handler.command = 'GET'
        handler.reply = Mock()
        handler.connection = Mock()
        return handler

    def test_anonymous_denied(self):
        handler = self.handler('')
        handler.handle_request()
        self.assertEqual(handler.reply.call_args.args[0], 401)

    def test_non_admin_denied(self):
        handler = self.handler()
        with patch.object(agent.jwt, 'decode', return_value={'shop_role': 'STAFF'}):
            handler.handle_request()
        self.assertEqual(handler.reply.call_args.args[0], 403)

    def test_invalid_token_denied(self):
        handler = self.handler()
        with patch.object(agent.jwt, 'decode', side_effect=agent.jwt.InvalidTokenError):
            handler.handle_request()
        self.assertEqual(handler.reply.call_args.args[0], 401)

    def test_request_without_app_header_denied(self):
        handler = self.handler()
        handler.headers.pop('X-POS-Wifi')
        with patch.object(agent.jwt, 'decode', return_value={'shop_role': 'ADMIN'}):
            handler.handle_request()
        self.assertEqual(handler.reply.call_args.args[0], 403)

    def test_admin_status_requires_fixed_algorithm_and_claims(self):
        handler = self.handler()
        with patch.object(agent.jwt, 'decode', return_value={'shop_role': 'ADMIN'}) as decode, patch.object(agent, 'status', return_value={'addresses': []}):
            handler.handle_request()
        self.assertEqual(handler.reply.call_args.args[0], 200)
        self.assertEqual(decode.call_args.kwargs['algorithms'], ['RS256'])
        self.assertIn('exp', decode.call_args.kwargs['options']['require'])


if __name__ == '__main__':
    unittest.main()
