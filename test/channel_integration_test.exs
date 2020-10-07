defmodule ChannelIntegrationTest do
  use ExUnit.Case

  alias ChannelSenderEx.Core.ProtocolMessage
  alias ChannelSenderEx.Transport.EntryPoint
  alias ChannelSenderEx.Core.Security.ChannelAuthenticator
  alias ChannelSenderEx.Core.ProtocolMessage
  alias ChannelSenderEx.Core.RulesProvider.Helper
  alias ChannelSenderEx.Core.RulesProvider
  alias ChannelSenderEx.Core.ChannelSupervisor
  alias ChannelSenderEx.Core.ChannelRegistry
  alias ChannelSenderEx.Core.RulesProvider.Helper

  @moduletag :capture_log

  @supervisor_module Application.get_env(:channel_sender_ex, :channel_supervisor_module)
  @registry_module Application.get_env(:channel_sender_ex, :registry_module)

  setup_all do
    IO.puts("Starting Applications for Socket Test")
    {:ok, _} = Application.ensure_all_started(:cowboy)
    {:ok, _} = Application.ensure_all_started(:gun)
    {:ok, _} = Application.ensure_all_started(:plug_crypto)
    Helper.compile(:channel_sender_ex)

    ext_message = %{
      message_id: "id_msg0001",
      correlation_id: "1111",
      message_data: "Some_messageData",
      event_name: "event.example"
    }

    {:ok, pid_registry} = @registry_module.start_link(name: ChannelRegistry, keys: :unique)
    {:ok, pid_supervisor} = @supervisor_module.start_link(name: ChannelSupervisor, strategy: :one_for_one)

    on_exit(fn ->
      true = Process.exit(pid_registry, :normal)
      true = Process.exit(pid_supervisor, :normal)
      IO.puts("Supervisor and Registry was terminated")
    end)

    message = ProtocolMessage.to_protocol_message(ext_message)
    {:ok, ext_message: ext_message, message: message}
  end

  setup do
    [ok: _] = EntryPoint.start(0)
    port = :ranch.get_port(:external_server)

    on_exit(fn ->
      :ok = :cowboy.stop_listener(:external_server)
    end)

    {channel, secret} = ChannelAuthenticator.create_channel("App1", "User1234")
    {:ok, port: port, channel: channel, secret: secret}
  end

  test "Should change channel state to waiting when connection closes", %{port: port, channel: channel, secret: secret} do
    {conn, stream} = assert_connect_and_authenticate(port, channel, secret)
    assert {:accepted_connected, _, _} = deliver_message(channel)
    assert_receive {:gun_ws, ^conn, ^stream, {:text, data_string}}
    :gun.close(conn)
    Process.sleep(100)
    assert {:accepted_waiting, _, _} = deliver_message(channel)
  end

  defp deliver_message(channel, message_id \\ "42") do
    data = "MessageData12_3245rs42112aa"
    message = ProtocolMessage.to_protocol_message(%{
      message_id: message_id,
      correlation_id: "",
      message_data: data,
      event_name: "event.test"
    })
    channel_response = ChannelSenderEx.Core.PubSub.PubSubCore.deliver_to_channel(channel, message)
    {channel_response, message_id, data}
  end

  defp assert_connect_and_authenticate(port, channel, secret) do
    conn = connect(port, channel)
    assert_receive {:gun_upgrade, ^conn, stream, ["websocket"], _headers}
    :gun.ws_send(conn, {:text, "Auth::#{secret}"})

    assert_receive {:gun_ws, ^conn, ^stream, {:text, data_string}}
    message = decode_message(data_string)
    assert "AuthOk" == ProtocolMessage.event_name(message)
    {conn, stream}
  end

  defp connect(port, channel) do
    {:ok, conn} = :gun.open('127.0.0.1', port)
    {:ok, _} = :gun.await_up(conn)
    :gun.ws_upgrade(conn, "/ext/socket?channel=#{channel}")
    conn
  end

  @spec decode_message(String.t()) :: ProtocolMessage.t()
  defp decode_message(string_data) do
    socket_message = Jason.decode!(string_data)
    ProtocolMessage.from_socket_message(socket_message)
  end

end