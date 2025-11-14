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
