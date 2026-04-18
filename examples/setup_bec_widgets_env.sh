#!/usr/bin/env bash
set -euo pipefail

bec_core_branch="${BEC_CORE_BRANCH:-main}"
ophyd_devices_branch="${OPHYD_DEVICES_BRANCH:-main}"
plugin_repo_branch="${PLUGIN_REPO_BRANCH:-main}"
python_version="${PYTHON_VERSION:-3.11}"

if command -v conda >/dev/null 2>&1; then
  conda_base="$(conda info --base)"
  source "$conda_base/etc/profile.d/conda.sh"
fi

echo "Using branch ${bec_core_branch} of BEC CORE"
git clone --branch "$bec_core_branch" https://github.com/bec-project/bec.git

echo "Using branch ${ophyd_devices_branch} of OPHYD_DEVICES"
git clone --branch "$ophyd_devices_branch" https://github.com/bec-project/ophyd_devices.git

echo "Using branch ${plugin_repo_branch} of bec_testing_plugin"
git clone --branch "$plugin_repo_branch" https://github.com/bec-project/bec_testing_plugin.git

conda create -q -n test-environment "python=${python_version}"
conda activate test-environment

cd bec
source ./bin/install_bec_dev.sh -t
cd ..

python -m pip install -e ./ophyd_devices -e .[dev,pyside6] -e ./bec_testing_plugin

benchmark_tmp_dir="$(mktemp -d)"
export BEC_SERVICE_CONFIG="$benchmark_tmp_dir/services_config.yaml"
redis-server \
  --bind 127.0.0.1 \
  --port 6379 \
  --save "" \
  --appendonly no \
  --dir "$benchmark_tmp_dir" &
redis_pid=$!

cleanup_benchmark_services() {
  if kill -0 "$redis_pid" >/dev/null 2>&1; then
    kill "$redis_pid"
    wait "$redis_pid" || true
  fi
  rm -rf "$benchmark_tmp_dir"
}
trap cleanup_benchmark_services EXIT

python - <<'PY'
import os
import shutil
import time
from pathlib import Path

import bec_lib
from bec_ipython_client import BECIPythonClient
from bec_lib.redis_connector import RedisConnector
from bec_lib.service_config import ServiceConfig, ServiceConfigModel
from redis import Redis

host = "127.0.0.1"
port = 6379
deadline = time.monotonic() + 10
client = Redis(host=host, port=port)
while time.monotonic() < deadline:
    try:
        if client.ping():
            break
    except Exception:
        time.sleep(0.1)
else:
    raise RuntimeError(f"Redis did not start on {host}:{port}")

files_path = Path(os.environ["BEC_SERVICE_CONFIG"]).parent
bec_lib_path = Path(bec_lib.__file__).resolve().parent
shutil.copyfile(bec_lib_path / "tests" / "test_config.yaml", files_path / "test_config.yaml")
services_config = Path(os.environ["BEC_SERVICE_CONFIG"])
service_config = ServiceConfigModel(
    redis={"host": host, "port": port},
    file_writer={"base_path": str(files_path)},
)
services_config.write_text(service_config.model_dump_json(indent=4), encoding="utf-8")

bec = BECIPythonClient(ServiceConfig(services_config), RedisConnector, forced=True)
bec.start()
try:
    bec.config.load_demo_config()
finally:
    bec.shutdown()
    bec._client._reset_singleton()

with open(os.environ["GITHUB_ENV"], "a", encoding="utf-8") as stream:
    stream.write(f"BEC_SERVICE_CONFIG={services_config}\n")
PY
