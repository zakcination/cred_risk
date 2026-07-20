"""SQL Server connection helper for the local analyst scripts under scripts/.

ПРОСТЫМ ЯЗЫКОМ: подключение к MSSQL по данным из файла .env (сервер, база,
логин/пароль или Windows-аутентификация). Используется скриптами анализа
(например, stage3_dpd_chart.py) — не входит в устанавливаемый пакет
topic_classifier.

Expects a `.env` file (default: repo root) with:
    SQL_SERVER=your-server\\instance,1433
    SQL_DATABASE=CL_PORTFOLIO        # optional, defaults to CL_PORTFOLIO
    SQL_USER=...                     # optional; omit for Windows auth (Trusted_Connection)
    SQL_PASSWORD=...                 # required if SQL_USER is set
"""

from __future__ import annotations

import os
from pathlib import Path

from dotenv import load_dotenv

ENV_PATH = Path(__file__).resolve().parent.parent / ".env"


def _load_env() -> None:
    if not ENV_PATH.exists():
        raise FileNotFoundError(f"Missing env file: {ENV_PATH}")
    load_dotenv(ENV_PATH)


def _build_conn_str() -> str:
    server = os.getenv("SQL_SERVER", "").strip()
    database = os.getenv("SQL_DATABASE", "").strip() or "CL_PORTFOLIO"
    user = os.getenv("SQL_USER", "").strip()
    pwd = os.getenv("SQL_PASSWORD", "").strip()

    if not server:
        raise RuntimeError("SQL_SERVER is missing in .env")

    if user:
        return (
            "DRIVER={ODBC Driver 17 for SQL Server};"
            f"SERVER={server};"
            f"DATABASE={database};"
            f"UID={user};"
            f"PWD={pwd};"
            "TrustServerCertificate=yes;"
            "Connection Timeout=30;"
        )

    return (
        "DRIVER={ODBC Driver 17 for SQL Server};"
        f"SERVER={server};"
        f"DATABASE={database};"
        "Trusted_Connection=yes;"
        "TrustServerCertificate=yes;"
        "Connection Timeout=30;"
    )


def connect():
    """Load .env and return an open pyodbc connection (autocommit=True).

    pyodbc is imported lazily so scripts that only use --demo mode (no DB)
    don't need the ODBC driver installed.
    """
    import pyodbc  # local import: only required for real DB access

    _load_env()
    return pyodbc.connect(_build_conn_str(), autocommit=True)
