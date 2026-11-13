defmodule Humdinger.App do
  @moduledoc "Application entry point for Humdinger."

  use Mob.App

  alias Humdinger.FMutate

  # The development node mob.connect attaches to (Mob.Dist, Android).
  @dev_node :"humdinger_android@127.0.0.1"

  @impl Mob.App
  def navigation(_platform) do
    stack(:main, root: Humdinger.LiveScreen)
  end

  @impl Mob.App
  def on_start do
    # Configure BEAM's DNS path so Req / Finch / Mint / `gen_tcp:connect/3`
    # with a hostname work on iOS without per-host setup. Flips the lookup
    # chain from the iOS-broken `:native` (inet_gethost port program) path
    # to `[:file, :dns]` and seeds Google + Cloudflare as fallback
    # nameservers. Override with `nameservers:` if you need to (corporate
    # resolver, Quad9, etc.) — see `Mob.DNS.configure_pure_beam/1`.
    #
    # For hosts that need Apple's resolver (VPN-pushed DNS, mDNS,
    # captive portals, search-domain expansion) call `Mob.DNS.resolve/1`
    # for those specific hostnames here too. Both paths compose.
    Mob.DNS.configure_pure_beam()

    {:ok, _} = Application.ensure_all_started(:ecto_sqlite3)
    {:ok, _} = Humdinger.Repo.start_link()

    Ecto.Migrator.with_repo(Humdinger.Repo, fn repo ->
      Ecto.Migrator.run(repo, migrations_dir(), :up, all: true)
    end)

    # Where the MIDI goes: FMutate, the Humdinger port, USB and Bluetooth MIDI.
    # Lives outside the screens so it keeps sending while FMutate is in front.
    {:ok, _} = Humdinger.Output.start_link()

    Mob.Theme.set(Humdinger.Style.theme())

    # The real-time path lives outside the screens, so it keeps listening
    # while another app is in front. It starts off; Live calls listen/0.
    {:ok, _} = Humdinger.Engine.start_link()

    # Humdinger is held in portrait, like a phone normally is.
    Mob.Device.lock_orientation(:portrait)
    Mob.Screen.start_root(Humdinger.LiveScreen)

    # The FMutate link: its port mapper has to be in place before any
    # distribution starts (including Mob.Dist's development node below).
    FMutate.Transport.setup(dev_node: @dev_node)
    {:ok, _} = FMutate.Supervisor.start_link()
    Mob.Dist.ensure_started(node: @dev_node, cookie: :mob_secret)
  end

  # Returns the path to the migrations directory for the current environment.
  #
  # WHY NOT Application.app_dir/2?
  #
  # Application.app_dir(app, "priv/repo/migrations") calls :code.priv_dir(app)
  # under the hood. That works in a normal `mix run` dev environment where the
  # app lives in $OTP_ROOT/lib/APP-VERSION/ebin/.
  #
  # On Android and iOS, Mob deploys .beam files to a flat -pa directory with no
  # versioned lib structure, so :code.priv_dir/1 returns {error, bad_name}.
  # Ecto.Migrator.run/3 silently finds zero migrations and logs "Migrations
  # already up" — tables are never created and any query against them crashes
  # the screen GenServer, making the screen appear frozen.
  #
  # The fix: mob_beam.c/mob_beam.m set MOB_BEAMS_DIR=beams_dir before erl_start.
  # The deployer pushes priv/ into beams_dir/priv/ and runs chmod -R 755 on it
  # (mkdir-as-root creates system:system drwxrwx--x dirs that the app process
  # can traverse but not list, breaking Path.wildcard). Here we read MOB_BEAMS_DIR
  # and pass the explicit path to Ecto.Migrator.run/4.
  defp migrations_dir do
    case System.get_env("MOB_BEAMS_DIR") do
      nil -> Application.app_dir(:humdinger, "priv/repo/migrations")
      beams_dir -> Path.join([beams_dir, "priv", "repo", "migrations"])
    end
  end
end
