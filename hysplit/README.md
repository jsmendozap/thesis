# HYSPLIT & ERA5 Automated Workflow

This project provides a fully automated, robust, and parallelized workflow to run the **HYSPLIT** trajectory model using **ERA5** meteorological data. It is designed for large-scale simulations on a Linux server, handling everything from dependency compilation to data processing and execution monitoring.

The workflow is orchestrated by a main script and is composed of three core stages:

1.  **Setup (`setup.sh`)**: A one-time script that prepares the entire environment by downloading and compiling HYSPLIT, the `era52arl` converter, and all necessary dependencies like `eccodes`.
2.  **Configuration (`config.json`)**: A single JSON file where all simulation parameters are defined—from the time range and receptor points to the specific ERA5 variables.
3.  **Execution (`main.sh`)**: The master script that launches and supervises the entire pipeline. It triggers data download, conversion, and HYSPLIT simulations, providing real-time progress updates via Telegram.

---

## Requirements

- **Operating System**: A modern Linux distribution (e.g., Ubuntu 20.04+).
- **System Tools**: `gfortran`, `gcc`, `g++`, `cmake`, `curl`, `jq`, `unzip`, `tar`, `sed`.
- **Python 3**: Required for helper scripts.
- **Credentials**: A `.env` file in the project's root directory containing API keys:

  ```.env
  # Copernicus Climate Data Store (CDS) API Key
  KEY="your_cds_api_key"

  # Telegram Bot credentials for notifications
  TOKEN="your_telegram_bot_token"
  CHAT_ID="your_telegram_chat_id"
  ```

---

## Step-by-Step Workflow

### 1. Initialization

Run the setup script to prepare the project structure and compile all dependencies. This only needs to be done once.

```bash
chmod +x setup.sh
./setup.sh
```

### 2. Configuration

Execute the "pre-processing" tasks in the `_targets.R` file, which creates the `config.json` file in the project root defining the parameters of the simulation.

> Note on Backward Trajectories: To run backward trajectories, set `date_start` to be chronologically after `date_end`. The scripts will automatically handle the negative duration.

### 3. Execution

Launch the main orchestrator. It will run in the background, manage all subprocesses, and send progress updates to your Telegram chat.

```bash
# Start the entire pipeline
./scripts/main.sh
```

---

## Project Structure

The setup.sh script creates the following directory structure:

- bin/: Executables for HYSPLIT, era52arl, and duckdb.
- data/: Houses all meteorological data.
  - GRIB/: Raw .GRIB files downloaded from Copernicus.
  - ARL/: HYSPLIT-ready .ARL files.
- deps/: Locally compiled dependencies (e.g., eccodes).
- output/: Contains all simulation results.
  - raw/: Raw text output from HYSPLIT (.txt).
  - parquet/: Final results, converted to efficient .parquet format.
- run/: The active working directory for simulations.
  - log/: Log files for all background processes.
- scripts/: All the Bash scripts that drive the workflow.
- status/: Lock files (.lock) and status files for process management and monitoring.
- tarballs/: Downloaded source code archives (.tar.gz, .zip).

---

## Key Features & Technical Details

- **Robust Orchestration**: The `main.sh` script supervises the entire process. It uses `trap` to ensure a clean shutdown and cleanup of status files if interrupted.

- **Asynchronous & Event-Driven**: The workflow is not strictly sequential. The download, conversion, and execution scripts are triggered in the background. For example, the conversion script is called as soon as a data chunk is downloaded, and the execution script is triggered after each new ARL file is created.

- **Concurrency Control**: The system uses `flock` to create `.lock` files (`conversion.lock`, `execution.lock`), preventing race conditions and ensuring that, for instance, the conversion process doesn't run while a previous instance is still active.

- **Parallel Execution**: HYSPLIT simulations are executed in parallel using `xargs -P`, significantly speeding up runs with many time steps. The number of parallel jobs is configurable.

- **Efficient Data Output**: Trajectory results are immediately converted from raw text to **Apache Parquet** format using `duckdb-cli`. This provides a compressed, columnar storage format that is highly optimized for fast analytical queries.

- **Real-time Monitoring**: The `main.sh` script periodically sends "heartbeat" messages to a configured Telegram chat, providing a snapshot of the progress for downloads, conversions, and completed simulations.

- **Dynamic Configuration**: Scripts dynamically generate HYSPLIT `CONTROL` and `SETUP.CFG` files based on the `config.json`, making each run self-contained and reproducible.

---

## Credits

The generation of mappings for `era52arl.cfg` is based on the `era5utils.py` script provided by the hysplit_metdata repository.
