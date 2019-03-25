#!/usr/bin/env python3

from mediawords.db import connect_to_db
from mediawords.job import AbstractJob, JobBrokerApp
from mediawords.util.log import create_logger
from mediawords.util.perl import decode_object_from_bytes_if_needed
from mediawords.util.sitemap.media import fetch_sitemap_pages_for_media_id

log = create_logger(__name__)


class FetchMediaPages(AbstractJob):
    """

    Fetch all media's pages (news stories and not) from XML sitemap.

    Start this worker script by running:

        ./script/run_in_env.sh ./mediacloud/mediawords/job/sitemap/fetch_media_pages.py

    """

    @classmethod
    def run_job(cls, media_id: int) -> None:
        if isinstance(media_id, bytes):
            media_id = decode_object_from_bytes_if_needed(media_id)

        media_id = int(media_id)

        db = connect_to_db()

        fetch_sitemap_pages_for_media_id(db=db, media_id=media_id)

    @classmethod
    def queue_name(cls) -> str:
        return 'MediaWords::Job::Sitemap::FetchMediaPages'


if __name__ == '__main__':
    app = JobBrokerApp(job_class=FetchMediaPages)
    app.start_worker()
