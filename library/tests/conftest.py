import os
import sys
import tempfile
from pathlib import Path

import pytest

# Add the project root directory to sys.path so we can import the modules
sys.path.insert(0, str(Path(__file__).parent.parent))


@pytest.fixture
def ansible_module_params():
    """Provide default parameters for AnsibleModule mock"""
    return {"params": {}, "check_mode": False}


@pytest.fixture
def temp_config_file():
    """Create a temporary configuration file for testing"""
    with tempfile.NamedTemporaryFile(mode="w", delete=False, suffix=".conf") as f:
        yield f.name
    os.unlink(f.name)


@pytest.fixture
def temp_dir():
    """Create a temporary directory for testing"""
    temp_dir = tempfile.mkdtemp()
    yield temp_dir
    # Cleanup the temporary directory after the test
    import shutil

    shutil.rmtree(temp_dir, ignore_errors=True)


@pytest.fixture
def mock_ansible_module(mocker):
    """Create a standardized mock Ansible module for testing"""
    mock_module = mocker.Mock()
    mock_module.params = {}
    mock_module.check_mode = False
    mock_module.fail_json = mocker.Mock(side_effect=SystemExit)
    mock_module.exit_json = mocker.Mock()
    mock_module.warn = mocker.Mock()
    mock_module.run_command = mocker.Mock(return_value=(0, "", ""))
    return mock_module
