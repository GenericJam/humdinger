defmodule Humdinger.FMutate.Reference.InstanceTest do
  # Protocol §4.1: FMutate releases a sibling's notes when the sibling's node goes.
  use ExUnit.Case, async: true

  alias Humdinger.FMutate.Reference.Instance

  setup do
    name = :"instance_#{System.unique_integer([:positive])}"
    {:ok, instance} = Instance.start_link(name: name, sink: self())
    sibling = spawn(fn -> Process.sleep(:infinity) end)
    GenServer.cast(instance, {:fmutate, 1, "a", {:subscribe, sibling, [:status]}})
    %{instance: instance, sibling: sibling}
  end

  defp midi(instance, bytes) do
    GenServer.cast(instance, {:fmutate, 1, "a", {:midi, bytes}})
    assert_receive {:fmutate_input, {:midi, ^bytes}}
  end

  test "a lost sibling's sounding notes are released, with CC 123 on their channels", ctx do
    midi(ctx.instance, <<0x90, 60, 100, 0x91, 64, 90, 0x92, 67, 90>>)
    midi(ctx.instance, <<0x80, 60, 64>>)
    # CC 123 already ended channel 3's note.
    midi(ctx.instance, <<0xB2, 123, 0>>)

    Process.exit(ctx.sibling, :noconnection)

    assert_receive {:fmutate_input, {:midi, <<0x81, 64, 64, 0xB1, 123, 0>>}}
    assert {:midi, <<0x81, 64, 64, 0xB1, 123, 0>>} in Instance.inputs(ctx.instance)
  end

  test "a sibling process that dies while its node stays connected leaves its notes alone", ctx do
    midi(ctx.instance, <<0x90, 60, 100>>)
    Process.exit(ctx.sibling, :kill)
    refute_receive {:fmutate_input, _}
  end
end
