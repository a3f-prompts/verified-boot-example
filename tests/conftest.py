# SPDX-License-Identifier: MIT
import os

import pytest


def pytest_addoption(parser):
    parser.addoption(
        "--bootchain-policy",
        default=os.environ.get("BOOTCHAIN_POLICY", "factory"),
        help="security policy the stage-2 barebox under test was built with",
    )


@pytest.fixture(scope="session")
def policy(pytestconfig):
    return pytestconfig.getoption("--bootchain-policy")


@pytest.fixture(scope="session")
def interactive(policy):
    """Whether the stage-2 policy allows console input at all."""
    return policy != "lockdown"
