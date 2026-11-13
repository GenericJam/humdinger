import Config

# Register the Repo so Mix tasks (mix ecto.create, mix ecto.migrate) can
# discover it. The actual database path is configured at runtime in
# Humdinger.Repo.init/2 via the MOB_DATA_DIR environment variable.
config :humdinger, ecto_repos: [Humdinger.Repo]

# Wire the Repo into Mob.ScreenState so screens using `vsn:` get automatic
# state persistence.
config :mob, :repo, Humdinger.Repo

# Host tests run without the Mob NIF, so screens skip device calls (screen
# size, keep-awake, permissions) there.
config :humdinger, device_calls: config_env() != :test

# The microphone: the hum_audio NIF on the phone, a scripted fake in host tests.
config :humdinger,
  audio: if(config_env() == :test, do: Humdinger.Audio.Fake, else: Humdinger.Audio.Native)

# Host tests use a fresh in-memory database each time the Repo starts.
if config_env() == :test do
  config :humdinger, Humdinger.Repo, database: ":memory:", log: false
end
