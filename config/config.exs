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
  audio: if(config_env() == :test, do: Humdinger.Audio.Fake, else: Humdinger.Audio.Native),
  # File sharing: Mob.Share on the phone, a reporting double in host tests.
  share: if(config_env() == :test, do: Humdinger.Test.Share, else: Mob.Share),
  # PDF printing: MobPrint on the phone, a reporting double in host tests.
  print: if(config_env() == :test, do: Humdinger.Test.Print, else: MobPrint),
  # Background microphone service: MobBackground on the phone, a fake in host tests.
  background: if(config_env() == :test, do: Humdinger.Test.FakeBackground, else: MobBackground)

# Humdinger's Android virtual MIDI device (read by mix mob_midi.gen.virtual_device).
config :mob_midi, :virtual_device,
  name: "Humdinger",
  inputs: 0,
  outputs: 1,
  manufacturer: "Humdinger"

if config_env() == :test do
  # Host tests use a fresh in-memory database each time the Repo starts.
  config :humdinger, Humdinger.Repo, database: ":memory:", log: false

  # Host tests keep secure-store values (the FMutate pairing) in a scratch
  # directory instead of the developer's data dir.
  config :mob_secure_store, dir: Path.join(System.tmp_dir!(), "humdinger_test_secure_store")
end
