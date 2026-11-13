defmodule Humdinger.Repo do
  use Ecto.Repo,
    otp_app: :humdinger,
    adapter: Ecto.Adapters.SQLite3

  @impl true
  def init(_type, config) do
    # MOB_DATA_DIR is set by mob_beam.c (Android) and mob_beam.m (iOS) to the
    # platform's appropriate persistent storage directory:
    #   Android — context.getFilesDir()  (app-private, survives updates)
    #   iOS     — NSDocumentDirectory    (app-private, iCloud-backed)
    #
    # When not running on device (e.g. mix ecto.migrate in dev), falls back to
    # priv/repo/ in the project root so local development works without any setup.
    #
    # A configured `database:` wins (host tests use an in-memory database).
    database =
      Keyword.get_lazy(config, :database, fn ->
        data_dir =
          System.get_env("MOB_DATA_DIR") ||
            System.get_env("HOME") ||
            Path.join(File.cwd!(), "priv/repo")

        File.mkdir_p!(data_dir)
        Path.join(data_dir, "app.db")
      end)

    {:ok, Keyword.merge(config, database: database, pool_size: 1)}
  end
end
