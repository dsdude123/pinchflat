defmodule Pinchflat.SlowIndexing.FileFollowerServer do
  @moduledoc """
  A GenServer that watches a file for new lines and processes them as they come in.
  This is useful for tailing log files and other similar tasks. If there's no activity
  for a certain amount of time, the server will stop itself.
  """
  use GenServer

  require Logger

  @poll_interval_ms Application.compile_env(:pinchflat, :file_watcher_poll_interval)
  @activity_timeout_ms 600_000

  # Client API
  @doc """
  Starts the file follower server.

  Accepts an optional keyword list of options:
    - `watching_pid`: A PID to monitor. If provided, the server will not stop
      due to inactivity while this process is still alive. This is useful for
      monitoring a process that is blocked waiting for an external command to
      complete (e.g., a yt-dlp indexing run). Defaults to nil.

  Returns {:ok, pid} or {:error, reason}
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc """
  Starts the file watcher for a given filepath and handler function.

  Returns :ok
  """
  def watch_file(process, filepath, handler) do
    GenServer.cast(process, {:watch_file, filepath, handler})
  end

  @doc """
  Stops the file watcher and closes the file.

  Returns :ok
  """
  def stop(process) do
    GenServer.cast(process, :stop)
  end

  # Server Callbacks
  @impl true
  def init(opts) do
    # Start with a blank state because, based on the common calling
    # pattern for this module, we'll need a reference to the server's
    # PID before we start watching any files so we can later stop the
    # server gracefully.
    watching_pid = Keyword.get(opts, :watching_pid, nil)

    {:ok, %{watching_pid: watching_pid}}
  end

  @impl true
  def handle_cast({:watch_file, filepath, handler}, old_state) do
    {:ok, io_device} = :file.open(filepath, [:raw, :read_ahead, :binary])

    state = %{
      io_device: io_device,
      last_activity: DateTime.utc_now(),
      handler: handler,
      watching_pid: old_state.watching_pid
    }

    Process.send(self(), :read_new_lines, [])

    {:noreply, state}
  end

  @impl true
  def handle_cast(:stop, state) do
    Logger.debug("Gracefully stopping file follower")
    :file.close(state.io_device)

    {:stop, :normal, state}
  end

  @impl true
  def handle_info(:read_new_lines, state) do
    last_activity = state.last_activity

    inactive = DateTime.diff(DateTime.utc_now(), last_activity, :millisecond) > @activity_timeout_ms
    process_done = not process_alive?(state.watching_pid)

    # If there's no new lines written for a certain amount of time AND the watching
    # process is no longer alive, stop the server. If the watching process is still
    # alive (eg: blocked in System.cmd waiting for yt-dlp to finish enumerating items),
    # keep waiting so we don't prematurely stop during large playlist indexing.
    if inactive && process_done do
      Logger.debug("No activity for #{@activity_timeout_ms}ms and watching process is done. Requesting stop.")
      stop(self())

      {:noreply, state}
    else
      attempt_process_new_lines(state)
    end
  end

  defp process_alive?(nil), do: false
  defp process_alive?(pid), do: Process.alive?(pid)

  defp attempt_process_new_lines(state) do
    io_device = state.io_device

    # This reads one line at a time. If a line is found, it
    # will be passed to the handler, we'll note the time of
    # the last activity, and then we'll immediately call this
    # again to read the next line.
    #
    # If there are no lines, it waits for the poll interval
    # before trying again.
    case :file.read_line(io_device) do
      {:ok, line} ->
        state.handler.(line)

        Process.send(self(), :read_new_lines, [])

        {:noreply, %{state | last_activity: DateTime.utc_now()}}

      :eof ->
        Logger.debug("Current batch of media processed. Will check again in #{@poll_interval_ms}ms")
        Process.send_after(self(), :read_new_lines, @poll_interval_ms)

        {:noreply, state}

      {:error, reason} ->
        Logger.error("Error reading file: #{reason}")
        stop(self())

        {:noreply, state}
    end
  end
end
