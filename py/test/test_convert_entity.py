# Convert entity test

import json
import os
import time

import pytest

from univec_sdk.utility.voxgig_struct import voxgig_struct as vs
from univec_sdk import UnivecSDK
from univec_sdk.core import helpers
from univec_sdk.config import shared_config
from univec_sdk.feature.base_feature import UnivecBaseFeature

_TEST_DIR = os.path.dirname(os.path.abspath(__file__))
from test import runner



# main.kit.test.live.strict is true (the default is true): a live
# request that fails, or a live test missing an input it needs,
# fails the test.
# An account with no record for a test to read skips it either way.
LIVE_STRICT = True


class TestConvertEntity:

    def test_should_create_instance(self):
        testsdk = UnivecSDK.test(None, None)
        ent = testsdk.Convert(None)
        assert ent is not None

    def test_should_refuse_an_invalid_request(self):
        if "validate" not in (shared_config().get("feature") or {}):
            pytest.skip("feature not present in this SDK: validate")
        client = UnivecSDK.test(
            None, {"feature": {"validate": {"active": True}}})
        with pytest.raises(Exception) as err:
            client.Convert(None).create({"embeddings": "x", "source_model": 1, "target_model": "x"}, None)
        assert "validate_failed" == getattr(err.value, "code", None)

    def test_should_run_basic_flow(self):
        setup = _convert_basic_setup(None)
        # Per-op sdk-test-control.json skip — basic test exercises a flow with
        # multiple ops; skipping any one skips the whole flow (steps depend
        # on each other).
        _live = setup.get("live", False)
        for _op in ["create"]:
            _skip, _reason = runner.is_control_skipped("entityOp", "convert." + _op, "live" if _live else "unit")
            if _skip:
                pytest.skip(_reason or "skipped via sdk-test-control.json")
                return
        client = setup["client"]

        # CREATE
        convert_ref01_ent = client.Convert(None)
        convert_ref01_data = helpers.to_map(vs.getprop(
            vs.getpath(setup["data"], "new.convert"), "convert_ref01"))

        convert_ref01_data = helpers.to_map(runner.entity_data(convert_ref01_ent.create(convert_ref01_data, None)))
        assert convert_ref01_data is not None



def _convert_basic_setup(extra):
    runner.load_env_local()

    entity_data_file = os.path.join(_TEST_DIR, "../../.sdk/test/entity/convert/ConvertTestData.json")
    with open(entity_data_file, "r", encoding="utf-8") as f:
        entity_data_source = f.read()

    entity_data = json.loads(entity_data_source)

    options = {}
    options["entity"] = entity_data.get("existing")

    client = UnivecSDK.test(options, extra)

    # Generate idmap via transform.
    idmap = vs.transform(
        ["convert01", "convert02", "convert03"],
        {
            "`$PACK`": ["", {
                "`$KEY`": "`$COPY`",
                "`$VAL`": ["`$FORMAT`", "upper", "`$COPY`"],
            }],
        }
    )

    # Whether *_ENTID supplied the idmap, read before env_override consumes
    # it: without it, the ids a live flow binds are the fixture's synthetic ones.
    _entid_env_raw = os.environ.get(
        "UNIVEC_TEST_CONVERT_ENTID")
    _idmap_overridden = _entid_env_raw is not None and _entid_env_raw.strip().startswith("{")

    env = runner.env_override({
        "UNIVEC_TEST_CONVERT_ENTID": idmap,
        "UNIVEC_TEST_LIVE": "FALSE",
        "UNIVEC_TEST_EXPLAIN": "FALSE",
        "UNIVEC_APIKEY": "",
    })

    idmap_resolved = helpers.to_map(
        env.get("UNIVEC_TEST_CONVERT_ENTID"))
    if idmap_resolved is None:
        idmap_resolved = helpers.to_map(idmap)

    if env.get("UNIVEC_TEST_LIVE") == "TRUE":
        merged_opts = vs.merge([
            # FIRST, so the generated fields below win: sdk-test-control.json's
            # test.client.options adds to the live client, it does not
            # redirect it.
            runner.live_client_options(),
            {
                "apikey": env.get("UNIVEC_APIKEY"),
            },
            extra or {},
        ])
        client = UnivecSDK(helpers.to_map(merged_opts))

    _live = env.get("UNIVEC_TEST_LIVE") == "TRUE"
    return {
        "client": client,
        "data": entity_data,
        "idmap": idmap_resolved,
        "env": env,
        "explain": env.get("UNIVEC_TEST_EXPLAIN") == "TRUE",
        "live": _live,
        "synthetic_only": _live and not _idmap_overridden,
        "now": int(time.time() * 1000),
    }
