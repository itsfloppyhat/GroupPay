"""Guest capability isolation, immutable approvals and durable transaction checks."""
import concurrent.futures
import copy
import unittest
import uuid

from cloud_app import create_app
from guest import GuestService, FirestoreGuestStore
from storage import StoreConflict, StoreUnavailable
from test_cloud_app import FakeIssuer, CLIENT_TOKEN
from test_storage import FakeFirestoreEngine, fake_store

PORTION = {"invitationID": str(uuid.uuid4()).upper(), "billID": str(uuid.uuid4()).upper(),
           "memberID": str(uuid.uuid4()).upper(), "cycle": 1, "title": "Dinner <script>",
           "name": "Alex", "foodCents": 1001, "taxCents": 80, "feeCents": 11, "tipCents": 200}


class GuestTests(unittest.TestCase):
    def setUp(self):
        self.now = 100000
        self.engine = FakeFirestoreEngine()
        self.service = self.new_service()
        self.client = create_app(FakeIssuer(), self.service).test_client()
        self.auth = {"Authorization": "Bearer " + CLIENT_TOKEN}
        self.guest = {"Authorization": "Guest " + self.service.token(PORTION["invitationID"])}

    def new_service(self):
        return GuestService(FirestoreGuestStore(fake_store(self.engine)), CLIENT_TOKEN, clock=lambda: self.now)

    def publish(self):
        return self.client.post('/v1/guest-invitations', json=PORTION, headers=self.auth)

    def approve(self, tip=250, **kwargs):
        return self.client.post('/guest-api/portion', json={"tipCents": tip}, headers=self.guest, **kwargs)

    def test_assets_are_public_private_apis_stay_private(self):
        for path in ['/guest', '/guest/guest.css', '/guest/guest.js']:
            result = self.client.get(path)
            self.assertEqual(result.status_code, 200)
            self.assertEqual(result.headers['Cache-Control'], 'no-store')
            self.assertEqual(result.headers['Referrer-Policy'], 'no-referrer')
            self.assertIn("frame-ancestors 'none'", result.headers['Content-Security-Policy'])
            result.close()
        self.assertEqual(self.client.get('/guest/other.js').status_code, 401)
        self.assertEqual(self.client.post('/v1/guest-invitations', json=PORTION).status_code, 401)
        self.assertEqual(self.client.post('/v1/cards', json={}, headers=self.guest).status_code, 401)
        self.assertEqual(self.client.get('/guest-api/portion', headers=self.auth).status_code, 404)

    def test_capability_is_advertised_only_with_durable_guest_service(self):
        self.assertTrue(self.client.get('/v1/status', headers=self.auth).json['supportsGuestApprovals'])
        unavailable = create_app(FakeIssuer()).test_client()
        self.assertFalse(unavailable.get('/v1/status', headers=self.auth).json['supportsGuestApprovals'])
        self.assertEqual(unavailable.post('/v1/guest-invitations', json=PORTION, headers=self.auth).status_code, 503)

    def test_link_returns_only_named_portion(self):
        response = self.publish()
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.json['token'], self.guest['Authorization'][6:])
        result = self.client.get('/guest-api/portion', headers=self.guest)
        self.assertEqual(result.json['portion'], PORTION)
        self.assertNotIn('token', result.json)
        self.assertNotIn(CLIENT_TOKEN, result.text)
        self.assertEqual(set(result.json), {'portion', 'closed', 'expired', 'expiresAt', 'approvedTipCents'})
        stranger = {'Authorization': 'Guest ' + self.service.token(str(uuid.uuid4()).upper())}
        self.assertEqual(self.client.get('/guest-api/portion', headers=stranger).status_code, 404)
        tampered = {'Authorization': self.guest['Authorization'][:-1] + 'z'}
        self.assertEqual(self.client.get('/guest-api/portion', headers=tampered).status_code, 404)

    def test_publish_is_immutable_and_idempotent(self):
        first = self.publish().json
        self.assertEqual(self.publish().json, first)
        changed = {**PORTION, 'foodCents': 1002}
        self.assertEqual(self.client.post('/v1/guest-invitations', json=changed, headers=self.auth).status_code, 409)

    def test_approval_is_final_and_retryable(self):
        self.publish()
        self.assertEqual(self.approve().json['approvedTipCents'], 250)
        self.assertEqual(self.approve().status_code, 200)
        self.assertEqual(self.approve(300).status_code, 409)
        saved = self.client.get('/v1/guest-invitations/' + PORTION['invitationID'], headers=self.auth)
        self.assertEqual(saved.json['approvedTipCents'], 250)
        self.assertEqual(self.new_service().read(PORTION['invitationID'])['approvedTipCents'], 250)

    def test_expiry_closure_and_key_rotation(self):
        self.publish()
        self.now += 7 * 86400
        self.assertTrue(self.client.get('/guest-api/portion', headers=self.guest).json['expired'])
        self.assertEqual(self.approve().status_code, 404)
        self.now -= 7 * 86400
        path = '/v1/guest-invitations/' + PORTION['invitationID'] + '/close'
        self.assertEqual(self.client.post(path, headers=self.guest).status_code, 401)
        self.assertTrue(self.client.post(path, headers=self.auth).json['closed'])
        self.assertEqual(self.approve().status_code, 404)
        self.assertTrue(self.publish().json['closed'])
        rotated = GuestService(FirestoreGuestStore(fake_store(self.engine)), 'another-key')
        with self.assertRaises(Exception): rotated.identify(self.guest['Authorization'][6:])

    def test_rejects_browser_cross_origin_and_url_credentials(self):
        self.publish()
        cross = {**self.guest, 'Origin': 'https://elsewhere.example'}
        self.assertEqual(self.client.post('/guest-api/portion', json={'tipCents': 0}, headers=cross).status_code, 403)
        cross = {**self.guest, 'Sec-Fetch-Site': 'cross-site'}
        self.assertEqual(self.client.get('/guest-api/portion', headers=cross).status_code, 403)
        same = {**self.guest, 'Origin': 'http://localhost', 'Sec-Fetch-Site': 'same-origin'}
        self.assertEqual(self.client.post('/guest-api/portion', json={'tipCents': 0}, headers=same).status_code, 200)
        tls = {**self.guest, 'Origin': 'https://localhost', 'Sec-Fetch-Site': 'same-origin'}
        self.assertEqual(self.client.post('/guest-api/portion', json={'tipCents': 0}, headers=tls).status_code, 200)
        self.assertEqual(self.client.get('/guest-api/portion?token=secret', headers=self.guest).status_code, 404)
        self.assertEqual(self.client.post('/v1/guest-invitations', json=PORTION, headers={**self.auth, 'Origin':'http://localhost'}).status_code, 403)

    def test_exact_cents_and_no_snapshot_editing(self):
        self.publish()
        for value in [-1, 1002, True, 12.5, '250', None]:
            self.assertEqual(self.approve(value).status_code, 422)
        response = self.client.post('/guest-api/portion', json={'tipCents': 0, 'foodCents': 0}, headers=self.guest)
        self.assertEqual(response.status_code, 422)
        self.assertIsNone(self.service.read(PORTION['invitationID'])['approvedTipCents'])
        for key, value in [('cycle', True), ('feeCents', -1), ('billID', 'wrong'), ('title', '')]:
            self.assertEqual(self.client.post('/v1/guest-invitations', json={**PORTION,key:value}, headers=self.auth).status_code, 422)

    def test_concurrent_conflicting_approvals_have_one_winner(self):
        self.publish()
        def approve(tip):
            try:
                return self.new_service().approve(PORTION['invitationID'], {'tipCents': tip})['approvedTipCents']
            except StoreConflict:
                return None
        with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
            results = list(pool.map(approve, range(100, 108)))
        self.assertEqual(len([r for r in results if r is not None]), 1)

    def test_lost_commit_ack_recovers_without_changing_approval(self):
        self.publish()
        self.engine.fail_after_commit_collection = 'guest_invitations'
        with self.assertRaises(StoreUnavailable):
            self.service.approve(PORTION['invitationID'], {'tipCents': 333})
        self.assertEqual(self.new_service().approve(PORTION['invitationID'], {'tipCents':333})['approvedTipCents'], 333)


if __name__ == '__main__': unittest.main()
