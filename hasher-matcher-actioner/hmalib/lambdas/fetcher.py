# Copyright (c) Facebook, Inc. and its affiliates. All Rights Reserved

"""
Implementation of the "fetcher" module of HMA.

Fetching involves connecting to the ThreatExchange API and downloading
signals to synchronize a local copy of the database, which will then
be fed into various indices.
"""

import logging
import os
import typing as t
from dataclasses import dataclass
from datetime import datetime
from functools import lru_cache

import boto3
from threatexchange.api import ThreatExchangeAPI
from threatexchange.signal_type.pdq import PdqSignal
from threatexchange.signal_type.md5 import VideoMD5Signal

from hmalib.aws_secrets import AWSSecrets
from hmalib.common.config import HMAConfig
from hmalib.common.logging import get_logger
from hmalib.common.fetcher_models import ThreatExchangeConfig
from hmalib.common.s3_adapters import ThreatUpdateS3Store


logger = get_logger(__name__)
s3 = boto3.resource("s3")
dynamodb = boto3.resource("dynamodb")

# Lambda init tricks
@lru_cache(maxsize=1)
def lambda_init_once():
    """
    Do some late initialization for required lambda components.

    Lambda initialization is weird - despite the existence of perfectly
    good constructions like __name__ == __main__, there don't appear
    to be easy ways to split your lambda-specific logic from your
    module logic except by splitting up the files and making your
    lambda entry as small as possible.

    TODO: Just refactor this file to separate the lambda and functional
          components
    """
    cfg = FetcherConfig.get()
    HMAConfig.initialize(cfg.config_table_name)


@dataclass
class FetcherConfig:
    """
    Simple holder for getting typed environment variables
    """

    s3_bucket: str
    s3_te_data_folder: str
    config_table_name: str
    data_store_table: str

    @classmethod
    @lru_cache(maxsize=None)  # probably overkill, but at least it's consistent
    def get(cls):
        # These defaults are naive but can be updated for testing purposes.
        return cls(
            s3_bucket=os.environ["THREAT_EXCHANGE_DATA_BUCKET_NAME"],
            s3_te_data_folder=os.environ["THREAT_EXCHANGE_DATA_FOLDER"],
            config_table_name=os.environ["CONFIG_TABLE_NAME"],
            data_store_table=os.environ["DYNAMODB_DATASTORE_TABLE"],
        )


def is_int(int_string: str):
    """
    Checks if string is convertible to int.
    """
    try:
        int(int_string)
        return True
    except ValueError:
        return False


def lambda_handler(event, context):
    lambda_init_once()
    config = FetcherConfig.get()
    collabs = ThreatExchangeConfig.get_all()

    now = datetime.now()
    current_time = now.strftime("%H:%M:%S")

    names = [collab.privacy_group_name for collab in collabs[:5]]
    if len(names) < len(collabs):
        names[-1] = "..."

    data = f"Triggered at time {current_time}, found {len(collabs)} collabs: {', '.join(names)}"
    logger.info(data)

    api_key = AWSSecrets().te_api_key()
    api = ThreatExchangeAPI(api_key)

    te_data_bucket = s3.Bucket(config.s3_bucket)

    for collab in collabs:
        logger.info(
            "Processing updates for collaboration %s", collab.privacy_group_name
        )

        if not is_int(collab.privacy_group_id):
            logger.info(
                f"Fetch skipped because privacy_group_id({collab.privacy_group_id}) is not an int"
            )
            continue

        indicator_store = ThreatUpdateS3Store(
            int(collab.privacy_group_id),
            api.app_id,
            te_data_bucket,
            config.s3_te_data_folder,
            config.data_store_table,
            supported_signal_types=[VideoMD5Signal, PdqSignal],
        )

        indicator_store.load_checkpoint()

        if indicator_store.stale:
            logger.warning(
                "Store for %s - %d stale! Resetting.",
                collab.privacy_group_name,
                int(collab.privacy_group_id),
            )
            indicator_store.reset()

        if indicator_store.fetch_checkpoint >= now.timestamp():
            continue

        delta = indicator_store.next_delta

        try:
            delta.incremental_sync_from_threatexchange(
                api,
            )
        except:
            # Don't need to call .exception() here because we're just re-raising
            logger.error("Exception occurred! Attempting to save...")
            # Force delta to show finished
            delta.end = delta.current
            raise
        finally:
            if delta:
                logging.info("Fetch complete, applying %d updates", len(delta.updates))
                indicator_store.apply_updates(
                    delta, post_apply_fn=indicator_store.post_apply
                )
            else:
                logging.error("Failed before fetching any records")
