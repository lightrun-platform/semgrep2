from pathlib import Path
from typing import Sequence

import pytest
from tests.conftest import make_semgrepconfig_file

from semgrep.project import ProjectConfig

CONFIG_TAGS = "tags:\n- tag1: value-1\n- tag2-as-string\n"
CONFIG_TAGS_MONOREPO_1 = (
    "tags:\n- tag1: value-1\n- tag2-as-string\n- service: service-1\n"
)
CONFIG_TAGS_MONOREPO_2 = (
    "tags:\n- tag1: value-1\n- tag2-as-string\n- service: service-2\n"
)


def create_mock_dir(git_tmp_path, files: Sequence[str]) -> None:
    for f in files:
        out_file = git_tmp_path / f
        out_file.parent.mkdir(parents=True, exist_ok=True)
        out_file.write_text("x = 1")


@pytest.mark.quick
def test_projectconfig__find_all_config_files_basic(git_tmp_path):
    dir_files = ["test.py", "main.py", "setup.py"]
    create_mock_dir(git_tmp_path, dir_files)
    make_semgrepconfig_file(git_tmp_path, CONFIG_TAGS)
    config_files = ProjectConfig._find_all_config_files(git_tmp_path, git_tmp_path)
    assert config_files == [git_tmp_path / ".semgrepconfig"]


@pytest.mark.quick
def test_projectconfig__find_all_config_files_monorepo(git_tmp_path):
    dir_files = [
        "service1/main.py",
        "service2/main.py",
    ]
    create_mock_dir(git_tmp_path, dir_files)
    service_1_dir = git_tmp_path / "service1"
    service_2_dir = git_tmp_path / "service2"

    # Root config file
    make_semgrepconfig_file(git_tmp_path, CONFIG_TAGS)
    # Service 1 config file
    make_semgrepconfig_file(service_1_dir, CONFIG_TAGS_MONOREPO_1)
    # Service 2 config file
    make_semgrepconfig_file(service_2_dir, CONFIG_TAGS_MONOREPO_2)

    config_files = ProjectConfig._find_all_config_files(git_tmp_path, service_1_dir)

    # Assert that it only contains config from root
    assert git_tmp_path / ".semgrepconfig" in config_files
    # Assert that it only contains config from service1
    assert service_1_dir / ".semgrepconfig" in config_files
    # Assert that it does not contain config from service2
    assert service_2_dir / ".semgrepconfig" not in config_files


@pytest.mark.quick
def test_projectconfig_load_all_basic(git_tmp_path, mocker):
    dir_files = ["test.py", "main.py", "setup.py"]
    create_mock_dir(git_tmp_path, dir_files)
    make_semgrepconfig_file(git_tmp_path, CONFIG_TAGS)

    mocker.patch.object(Path, "cwd", return_value=git_tmp_path)
    mocker.patch("semgrep.project.get_git_root_path", return_value=git_tmp_path)
    proj_config = ProjectConfig.load_all()

    expected_metadata = {
        "tags": [
            {"tag1": "value-1"},
            "tag2-as-string",
        ]
    }
    assert proj_config.metadata == expected_metadata


@pytest.mark.quick
def test_projectconfig_load_all_monorepo(git_tmp_path, mocker):
    dir_files = [
        "service1/main.py",
        "service2/main.py",
    ]
    create_mock_dir(git_tmp_path, dir_files)
    service_1_dir = git_tmp_path / "service1"
    service_2_dir = git_tmp_path / "service2"

    # Root config file
    make_semgrepconfig_file(git_tmp_path, CONFIG_TAGS)
    # Service 1 config file
    make_semgrepconfig_file(service_1_dir, CONFIG_TAGS_MONOREPO_1)
    # Service 2 config file
    make_semgrepconfig_file(service_2_dir, CONFIG_TAGS_MONOREPO_2)

    mocker.patch.object(Path, "cwd", return_value=service_1_dir)
    mocker.patch("semgrep.project.get_git_root_path", return_value=git_tmp_path)
    proj_config = ProjectConfig.load_all()

    expected_metadata = {
        "tags": [{"tag1": "value-1"}, "tag2-as-string", {"service": "service-1"}]
    }
    assert proj_config.metadata == expected_metadata


@pytest.mark.quick
def test_projectconfig_todict():
    project_config = ProjectConfig(
        {"tags": [{"tag1": "value-1"}, "tag2-as-string", {"service": "service-1"}]}
    )

    expected = {
        "tags": ['{"tag1": "value-1"}', "tag2-as-string", '{"service": "service-1"}']
    }
    assert project_config.to_dict() == expected
