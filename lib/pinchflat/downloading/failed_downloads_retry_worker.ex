defmodule Pinchflat.Downloading.FailedDownloadsRetryWorker do
  @moduledoc false

  use Oban.Worker,
    queue: :local_data,
    unique: [period: :infinity, states: [:available, :scheduled, :retryable, :executing]],
    tags: ["media_item", "local_data"]

  require Logger

  alias Pinchflat.Media
  alias Pinchflat.Downloading.MediaDownloadWorker

  @doc """
  Re-enqueues download jobs for any pending media items that have a recorded
  last_error (i.e. a previous download attempt failed).

  This worker is scheduled to run every 6 hours via the Oban Cron plugin.
  The unique constraint on MediaDownloadWorker prevents duplicate jobs from
  being created if a retry is already active.

  Returns :ok
  """
  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    errored_items = Media.list_errored_pending_media_items()
    Logger.info("Re-enqueuing #{length(errored_items)} failed media downloads for retry")

    Enum.each(errored_items, fn media_item ->
      MediaDownloadWorker.kickoff_with_task(media_item, %{})
    end)

    :ok
  end
end
