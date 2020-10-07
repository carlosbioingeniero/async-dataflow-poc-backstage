defmodule ChannelTest do
  use ExUnit.Case

  alias ChannelSenderEx.Core.Channel
  alias ChannelSenderEx.Core.ProtocolMessage

  @moduletag :capture_log

  setup do
    {:ok,
     init_args: {_channel = "chan322sdsd", _application = "app23324", _user_ref = "user234"},
     message: %{
       message_id: "32452",
       correlation_id: "1111",
       message_data: "Some_messageData",
       event_name: "event.example"
     }}
  end

  test "Should Send message when connected", %{init_args: init_args, message: message} do
    {:ok, pid} = start_channel_safe(init_args)
    :ok = Channel.socket_connected(pid, self())
    message_to_send = ProtocolMessage.to_protocol_message(message)
    :accepted_connected = Channel.deliver_message(pid, message_to_send)
    assert_receive {:deliver_msg, from = {^pid, ref}, ^message_to_send}
    Process.exit(pid, :kill)
  end

  test "On connect should deliver message", %{init_args: init_args, message: message} do
    {:ok, pid} = start_channel_safe(init_args)
    message_to_send = ProtocolMessage.to_protocol_message(message)
    :accepted_waiting = Channel.deliver_message(pid, message_to_send)
    refute_receive {_from = {^pid, _ref}, ^message_to_send}, 350
    :ok = Channel.socket_connected(pid, self())
    assert_receive {:deliver_msg, _from = {^pid, _ref}, ^message_to_send}
    Process.exit(pid, :kill)
  end

  test "Should re-deliver message when no ack", %{init_args: init_args, message: message} do
    {:ok, pid} = start_channel_safe(init_args)
    :ok = Channel.socket_connected(pid, self())
    message_to_send = ProtocolMessage.to_protocol_message(message)
    :accepted_connected = Channel.deliver_message(pid, message_to_send)
    assert_receive {:deliver_msg, from = {^pid, ref}, ^message_to_send}
    assert_receive {:deliver_msg, from = {^pid, ref}, ^message_to_send}, 200
    Process.exit(pid, :kill)
  end

  test "Should not re-deliver message ack is received", %{init_args: init_args, message: message} do
    {:ok, pid} = start_channel_safe(init_args)
    :ok = Channel.socket_connected(pid, self())
    message_to_send = ProtocolMessage.to_protocol_message(message)
    :accepted_connected = Channel.deliver_message(pid, message_to_send)
    assert_receive {:deliver_msg, _from = {^pid, ref}, ^message_to_send}
    Channel.notify_ack(pid, ref, message.message_id)
    refute_receive {:deliver_msg, _from = {^pid, _ref}, ^message_to_send}, 300
    Process.exit(pid, :kill)
  end

  test "Should not fail when multiples acks was received", %{
    init_args: init_args,
    message: message
  } do
    {:ok, pid} = start_channel_safe(init_args)
    :ok = Channel.socket_connected(pid, self())
    message_to_send = ProtocolMessage.to_protocol_message(message)
    :accepted_connected = Channel.deliver_message(pid, message_to_send)
    assert_receive {:deliver_msg, _from = {^pid, ref}, ^message_to_send}

    Channel.notify_ack(pid, ref, message.message_id)
    Process.sleep(70)
    Channel.notify_ack(pid, ref, message.message_id)
    Process.sleep(70)
    Channel.notify_ack(pid, ref, message.message_id)
    Process.sleep(70)

    refute_receive {:deliver_msg, _from = {^pid, _ref}, ^message_to_send}, 300

    :accepted_connected = Channel.deliver_message(pid, message_to_send)
    assert_receive {:deliver_msg, _from = {^pid, ref}, ^message_to_send}

    Process.exit(pid, :kill)
  end

  test "Should cancel retries on late ack", %{init_args: init_args, message: message} do
    {:ok, pid} = start_channel_safe(init_args)
    :ok = Channel.socket_connected(pid, self())
    message_to_send = ProtocolMessage.to_protocol_message(message)
    :accepted_connected = Channel.deliver_message(pid, message_to_send)
    assert_receive {:deliver_msg, _from = {^pid, ref}, ^message_to_send}
    # Receive retry
    assert_receive {:deliver_msg, _from = {^pid, _ref}, ^message_to_send}, 150

    # Late ack
    Channel.notify_ack(pid, ref, message.message_id)

    # Assert cancel retries
    refute_receive {:deliver_msg, _from = {^pid, _ref}, ^message_to_send}, 400

    Process.exit(pid, :kill)
  end

  test "Should postpone redelivery when Channel state change to waiting (disconnected)", %{init_args: init_args, message: message} do
    proxy = proxy_process()
    {:ok, channel_pid} = start_channel_safe(init_args)
#    :sys.trace(channel_pid, true)
    :ok = Channel.socket_connected(channel_pid, proxy)

    message_to_send = ProtocolMessage.to_protocol_message(message)
    assert :accepted_connected = Channel.deliver_message(channel_pid, message_to_send)
    assert_receive {:deliver_msg, _from = {^channel_pid, ref}, ^message_to_send}

    send(proxy, :stop)
    refute_receive {:deliver_msg, _from = {^channel_pid, ref}, ^message_to_send}, 350
    assert {:waiting, _data} = :sys.get_state(channel_pid)

    proxy = proxy_process()
    :ok = Channel.socket_connected(channel_pid, proxy)

    assert_receive {:deliver_msg, _from = {^channel_pid, ref}, ^message_to_send}
    assert_receive {:deliver_msg, _from = {^channel_pid, ref}, ^message_to_send}, 300

    send(proxy, :stop)
    Process.exit(channel_pid, :kill)
  end

  defp proxy_process() do
    pid = self()
    spawn(fn -> loop_and_resend(pid) end)
  end

  def loop_and_resend(target_pid) do
    receive do
      :stop ->
        nil
      any ->
        send(target_pid, any)
        loop_and_resend(target_pid)
    end
  end

  def start_channel_safe(args) do
    parent = self()
    ref = make_ref()

    spawn(fn ->
      send(parent, {ref, Channel.start_link(args)})
      Process.sleep(:infinity)
    end)

    receive do
      {^ref, result} -> result
    after
      1000 -> :timeout
    end
  end
end