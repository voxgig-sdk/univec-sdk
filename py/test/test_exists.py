# ProjectName SDK exists test

import pytest
from univec_sdk import UnivecSDK


class TestExists:

    def test_should_create_test_sdk(self):
        testsdk = UnivecSDK.test(None, None)
        assert testsdk is not None
