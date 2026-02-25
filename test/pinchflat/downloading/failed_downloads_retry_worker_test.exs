defmodule Pinchflat.Downloading.FailedDownloadsRetryWorkerTest do
  use Pinchflat.DataCase

  import Pinchflat.MediaFixtures
  import Pinchflat.SourcesFixtures

  alias Pinchflat.Downloading.FailedDownloadsRetryWorker

  describe "perform/1" do
    test "enqueues download jobs for pending media items with errors" do
      source = source_fixture()
      media_item = media_item_fixture(%{source_id: source.id, last_error: "some error"})

      perform_job(FailedDownloadsRetryWorker, %{})

      assert_enqueued(
        worker: Pinchflat.Downloading.MediaDownloadWorker,
        args: %{"id" => media_item.id}
      )
    end

    test "does not enqueue jobs for pending media items without errors" do
      source = source_fixture()
      _media_item = media_item_fixture(%{source_id: source.id, last_error: nil})

      perform_job(FailedDownloadsRetryWorker, %{})

      refute_enqueued(worker: Pinchflat.Downloading.MediaDownloadWorker)
    end

    test "does not enqueue jobs for already-downloaded media items" do
      source = source_fixture()

      _media_item =
        media_item_fixture(%{
          source_id: source.id,
          last_error: "some error",
          media_filepath: "/some/path.mp4",
          media_downloaded_at: DateTime.utc_now()
        })

      perform_job(FailedDownloadsRetryWorker, %{})

      refute_enqueued(worker: Pinchflat.Downloading.MediaDownloadWorker)
    end

    test "returns :ok" do
      assert :ok = perform_job(FailedDownloadsRetryWorker, %{})
    end
  end
end
