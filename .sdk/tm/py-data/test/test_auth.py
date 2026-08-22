# Univec Data — credential discovery tests.

from __future__ import annotations

import os

import pytest

from projectname_data import auth
from projectname_data.auth import resolve, from_env, missing_token_message, missing_base_message, NOT_FOUND


class TestResolve:

    def test_explicit_argument_wins(self, monkeypatch):
        monkeypatch.setenv("ACME_APIKEY", "from-env")
        tok, base, src = resolve("ACME", token="explicit")
        assert tok == "explicit"
        assert src == "argument"

    def test_env_fallback(self, monkeypatch):
        monkeypatch.setenv("ACME_APIKEY", "from-env")
        tok, base, src = resolve("ACME")
        assert tok == "from-env"
        assert src == "env"

    def test_missing_returns_none(self, monkeypatch):
        monkeypatch.delenv("ACME_APIKEY", raising=False)
        tok, base, src = resolve("ACME")
        assert tok is None
        assert src is None

    def test_base_url_from_env(self, monkeypatch):
        monkeypatch.setenv("ACME_APIKEY", "k")
        monkeypatch.setenv("ACME_BASE", "https://tenant.example.com")
        tok, base, src = resolve("ACME")
        assert base == "https://tenant.example.com"

    def test_explicit_base_wins(self, monkeypatch):
        monkeypatch.setenv("ACME_BASE", "https://env.example.com")
        tok, base, src = resolve("ACME", token="k", base_url="https://arg.example.com")
        assert base == "https://arg.example.com"

    def test_custom_keys(self, monkeypatch):
        monkeypatch.setenv("WEIRD_TOKEN", "k")
        tok, base, src = resolve("ACME", token_key="WEIRD_TOKEN")
        assert tok == "k"

    def test_empty_string_is_not_a_credential(self, monkeypatch):
        monkeypatch.setenv("ACME_APIKEY", "")
        tok, base, src = resolve("ACME")
        assert tok is None

    def test_colab_is_tried_before_env(self, monkeypatch):
        monkeypatch.setenv("ACME_APIKEY", "from-env")
        monkeypatch.setattr(auth, "from_colab",
                            lambda key: "from-colab" if key == "ACME_APIKEY" else NOT_FOUND)
        tok, base, src = resolve("ACME")
        assert tok == "from-colab"
        assert src == "colab"

    def test_colab_failure_falls_through_to_env(self, monkeypatch):
        # Outside Colab the import fails; inside Colab an ungranted secret
        # raises. Neither is an error here — both mean "try the next source".
        monkeypatch.setenv("ACME_APIKEY", "from-env")
        monkeypatch.setattr(auth, "from_colab", lambda key: NOT_FOUND)
        tok, base, src = resolve("ACME")
        assert tok == "from-env"


class TestFromEnv:

    def test_present(self, monkeypatch):
        monkeypatch.setenv("X_Y", "v")
        assert from_env("X_Y") == "v"

    def test_absent(self, monkeypatch):
        monkeypatch.delenv("X_Y", raising=False)
        assert from_env("X_Y") is NOT_FOUND


class TestMessages:

    def test_token_message_names_the_real_key(self):
        msg = missing_token_message("ACME")
        assert "ACME_APIKEY" in msg
        # It must teach, not just report: both environments, copy-pasteable.
        assert "userdata.set" in msg
        assert "os.environ" in msg
        assert "data(token=" in msg

    def test_base_message_names_the_real_key(self):
        msg = missing_base_message("ACME")
        assert "ACME_BASE" in msg
        assert "base_url=" in msg
