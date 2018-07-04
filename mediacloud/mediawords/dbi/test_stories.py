from mediawords.dbi.stories import mark_as_processed
from mediawords.test.db import create_test_medium, create_test_feed, create_test_story
from mediawords.test.test_database import TestDatabaseWithSchemaTestCase


class TestStories(TestDatabaseWithSchemaTestCase):

    def setUp(self) -> None:
        """Set config for tests."""
        super().setUp()

        self.test_medium = create_test_medium(self.db(), 'downloads test')
        self.test_feed = create_test_feed(self.db(), 'downloads test', self.test_medium)
        self.test_story = create_test_story(self.db(), label='downloads est', feed=self.test_feed)

    def test_mark_as_processed(self):
        processed_stories = self.db().query("SELECT * FROM processed_stories").hashes()
        assert len(processed_stories) == 0

        mark_as_processed(db=self.db(), stories_id=self.test_story['stories_id'])

        processed_stories = self.db().query("SELECT * FROM processed_stories").hashes()
        assert len(processed_stories) == 1
        assert processed_stories[0]['stories_id'] == self.test_story['stories_id']
