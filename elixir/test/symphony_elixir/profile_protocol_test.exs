defmodule SymphonyElixir.Codex.ProtocolTest do
  use ExUnit.Case, async: true
  alias SymphonyElixir.Codex.Protocol

  test "only explicit profile preservation removes legacy sandbox overrides" do
    thread = %{"id" => 1, "method" => "thread/start", "params" => %{"sandbox" => "workspace-write", "cwd" => "/workspace", "approvalPolicy" => "never"}}
    turn = %{"id" => 2, "method" => "turn/start", "params" => %{"sandboxPolicy" => %{"type" => "workspaceWrite"}, "threadId" => "thread"}}
    assert Protocol.preserve_profile(thread, false) == thread
    assert Protocol.preserve_profile(turn, false) == turn
    assert Protocol.preserve_profile(thread, true)["params"] == %{"cwd" => "/workspace", "approvalPolicy" => "never"}
    assert Protocol.preserve_profile(turn, true)["params"] == %{"threadId" => "thread"}
    initialize = %{"method" => "initialize", "params" => %{}}
    assert Protocol.preserve_profile(initialize, true) == initialize
  end
end
