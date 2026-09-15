defmodule Sigil.RuntimeTest do
  use ExUnit.Case, async: false

  test "cancel_all_runs is a no-op without runners" do
    assert :ok = Sigil.Runtime.cancel_all_runs()
  end

  test "mark_interrupted_runs is a no-op without sessions" do
    assert :ok = Sigil.Runtime.mark_interrupted_runs()
  end
end
