defmodule LiveExWebRTC.Subscriber do
  @moduledoc """
  Component for sending audio and video via WebRTC from a Phoenix app to a browser (browser subscribes).

  It will render a single HTMLVideoElement.

  Once rendered, your `Phoenix.LiveView` will receive `t:init_msg/0` and can start
  sending RTP packets to the browser using `ExWebRTC.PeerConnection.send_rtp/4`, where
  there first argument is a pid received in `t:init_msg/0`. For example:

  ```elixir
  ExWebRTC.PeerConnection.send_rtp(init_msg[:pc], init_msg[:audio_track_id], audio_packet)
  ExWebRTC.PeerConnection.send_rtp(init_msg[:pc], init_msg[:video_track_id], video_packet)
  ```

  Subscriber always negotiates a single audio and video track.

  ## Assigns

  * `ice_servers` - a list of `t:ExWebRTC.PeerConnection.Configuration.ice_server/0`,
  * `ice_ip_filter` - `t:ExICE.ICEAgent.ip_filter/0`,
  * `ice_port_range` - `t:Enumerable.t(non_neg_integer())/1`,
  * `audio_codecs` - a list of `t:ExWebRTC.RTPCodecParameters.t/0`,
  * `video_codecs` - a list of `t:ExWebRTC.RTPCodecParameters.t/0`,
  * `gen_server_name` - `t:GenServer.name/0`
  * `class` - list of CSS/Tailwind classes that will be applied to the HTMLVideoPlayer. Defaults to "".

  ## JavaScript Hook

  Subscriber live component requires JavaScript hook to be registered under `Subscriber` name.
  The hook can be created using `createSubscriberHook` function.
  For example:

  ```javascript
  import { createSubscriberHook } from "live_ex_webrtc";
  let Hooks = {};
  const iceServers = [{ urls: "stun:stun.l.google.com:19302" }];
  Hooks.Subscriber = createSubscriberHook(iceServers);
  let liveSocket = new LiveSocket("/live", Socket, {
    // ...
    hooks: Hooks
  });
  ```

  ## Examples

  ```elixir
  <.live_component
    module={LiveExWebRTC.Subscriber}
    id="subscriber"
    ice_servers={[%{urls: "stun:stun.l.google.com:19302"}]}
  />
  ```
  """
  use Phoenix.LiveView

  alias LiveExWebRTC.Subscriber

  defstruct id: nil,
            publisher_id: nil,
            pubsub: nil,
            pc: nil,
            audio_track_id: nil,
            video_track_id: nil,
            on_packet: nil,
            on_connected: nil,
            ice_servers: nil,
            ice_ip_filter: nil,
            ice_port_range: nil,
            audio_codecs: nil,
            video_codecs: nil,
            name: nil

  alias ExWebRTC.{ICECandidate, MediaStreamTrack, PeerConnection, SessionDescription}
  alias ExRTCP.Packet.PayloadFeedback.PLI
  alias Phoenix.PubSub

  attr(:socket, Phoenix.LiveView.Socket, required: true)
  attr(:subscriber, __MODULE__, required: true)
  attr(:class, :string, default: nil)

  def stream_viewer(assigns) do
    ~H"""
    <%= live_render(@socket, __MODULE__, id: @subscriber.id, session: %{
      "publisher_id" => @subscriber.publisher_id,
      "class" => @class
    }) %>
    """
  end

  def attach(socket, opts) do
    opts =
      Keyword.validate!(opts, [
        :id,
        :publisher_id,
        :name,
        :pubsub,
        :on_packet,
        :on_connected,
        :ice_servers,
        :ice_ip_filter,
        :ice_port_range,
        :audio_codecs,
        :video_codecs
      ])

    subscriber = %Subscriber{
      id: Keyword.fetch!(opts, :id),
      publisher_id: Keyword.fetch!(opts, :publisher_id),
      pubsub: Keyword.fetch!(opts, :pubsub),
      on_packet: Keyword.get(opts, :on_packet),
      on_connected: Keyword.get(opts, :on_connected),
      ice_servers: Keyword.get(opts, :ice_servers, [%{urls: "stun:stun.l.google.com:19302"}]),
      ice_ip_filter: Keyword.get(opts, :ice_ip_filter),
      ice_port_range: Keyword.get(opts, :ice_port_range),
      audio_codecs: Keyword.get(opts, :audio_codecs),
      video_codecs: Keyword.get(opts, :video_codecs),
      name: Keyword.get(opts, :name)
    }

    socket
    |> assign(subscriber: subscriber)
    |> attach_hook(:subscriber_infos, :handle_info, &attached_handle_info/2)
  end

  def render(%{subscriber: nil} = assigns) do
    ~H"""
    """
  end

  def render(assigns) do
    ~H"""
    <video id={@subscriber.id} phx-hook="Subscriber" class={@class} controls autoplay muted></video>
    """
  end

  def mount(_params, %{"publisher_id" => pub_id, "class" => class}, socket) do
    socket = assign(socket, class: class, subscriber: nil)

    if connected?(socket) do
      ref = make_ref()
      send(socket.parent_pid, {__MODULE__, {:attached, ref, self(), %{publisher_id: pub_id}}})

      socket =
        receive do
          {^ref, %Subscriber{publisher_id: ^pub_id} = subscriber} ->
            assign(socket, subscriber: subscriber)
        after
          5000 -> exit(:timeout)
        end

      {:ok, socket}
    else
      {:ok, socket}
    end
  end

  def handle_info({:ex_webrtc, _pid, {:connection_state_change, :connected}}, socket) do
    %{subscriber: sub} = socket.assigns
    PubSub.subscribe(sub.pubsub, "streams:audio:#{sub.publisher_id}")
    PubSub.subscribe(sub.pubsub, "streams:video:#{sub.publisher_id}")
    broadcast_keyframe_req(socket)
    if sub.on_connected, do: sub.on_connected.(sub.publisher_id)

    {:noreply, socket}
  end

  def handle_info({:ex_webrtc, _pc, {:rtcp, packets}}, socket) do
    # Browser, we are sending to, requested a keyframe.
    # Forward this request to the publisher.
    if Enum.any?(packets, fn {_, packet} -> match?(%PLI{}, packet) end) do
      broadcast_keyframe_req(socket)
    end

    {:noreply, socket}
  end

  def handle_info({:ex_webrtc, _pid, _}, socket) do
    {:noreply, socket}
  end

  def handle_info({:live_ex_webrtc, :audio, packet}, socket) do
    %{subscriber: sub} = socket.assigns
    PeerConnection.send_rtp(sub.pc, sub.audio_track_id, packet)
    if sub.on_packet, do: sub.on_packet.(sub.publisher_id, :audio, packet)
    {:noreply, socket}
  end

  def handle_info({:live_ex_webrtc, :video, packet}, socket) do
    %{subscriber: sub} = socket.assigns
    PeerConnection.send_rtp(sub.pc, sub.video_track_id, packet)
    if sub.on_packet, do: sub.on_packet.(sub.publisher_id, :video, packet)
    {:noreply, socket}
  end

  defp attached_handle_info({__MODULE__, {:attached, ref, pid, _meta}}, socket) do
    send(pid, {ref, socket.assigns.subscriber})
    {:halt, socket}
  end

  defp attached_handle_info(_msg, socket) do
    {:cont, socket}
  end

  def handle_event("offer", unsigned_params, socket) do
    %{subscriber: sub} = socket.assigns

    offer = SessionDescription.from_json(unsigned_params)
    {:ok, pc} = spawn_peer_connection(socket)

    :ok = PeerConnection.set_remote_description(pc, offer)

    stream_id = MediaStreamTrack.generate_stream_id()
    audio_track = MediaStreamTrack.new(:audio, [stream_id])
    video_track = MediaStreamTrack.new(:video, [stream_id])
    {:ok, _sender} = PeerConnection.add_track(pc, audio_track)
    {:ok, _sender} = PeerConnection.add_track(pc, video_track)
    {:ok, answer} = PeerConnection.create_answer(pc)
    :ok = PeerConnection.set_local_description(pc, answer)
    :ok = gather_candidates(pc)
    answer = PeerConnection.get_local_description(pc)

    new_sub = %Subscriber{
      sub
      | pc: pc,
        audio_track_id: audio_track.id,
        video_track_id: video_track.id
    }

    {:noreply,
     socket
     |> assign(subscriber: new_sub)
     |> push_event("answer-#{sub.id}", SessionDescription.to_json(answer))}
  end

  def handle_event("ice", "null", socket) do
    %{subscriber: sub} = socket.assigns

    case sub do
      %Subscriber{pc: nil} ->
        {:noreply, socket}

      %Subscriber{pc: pc} ->
        :ok = PeerConnection.add_ice_candidate(pc, %ICECandidate{candidate: ""})
        {:noreply, socket}
    end
  end

  def handle_event("ice", unsigned_params, socket) do
    %{subscriber: sub} = socket.assigns

    case sub do
      %Subscriber{pc: nil} ->
        {:noreply, socket}

      %Subscriber{pc: pc} ->
        cand =
          unsigned_params
          |> Jason.decode!()
          |> ExWebRTC.ICECandidate.from_json()

        :ok = PeerConnection.add_ice_candidate(pc, cand)

        {:noreply, socket}
    end
  end

  defp spawn_peer_connection(socket) do
    %{subscriber: sub} = socket.assigns

    pc_opts =
      [
        ice_servers: sub.ice_servers,
        ice_ip_filter: sub.ice_ip_filter,
        ice_port_range: sub.ice_port_range,
        audio_codecs: sub.audio_codecs,
        video_codecs: sub.video_codecs
      ]
      |> Enum.reject(fn {_k, v} -> v == nil end)

    gen_server_opts =
      [name: sub.name]
      |> Enum.reject(fn {_k, v} -> v == nil end)

    PeerConnection.start_link(pc_opts, gen_server_opts)
  end

  defp gather_candidates(pc) do
    # we either wait for all of the candidates
    # or whatever we were able to gather in one second
    receive do
      {:ex_webrtc, ^pc, {:ice_gathering_state_change, :complete}} -> :ok
    after
      1000 -> :ok
    end
  end

  defp broadcast_keyframe_req(socket) do
    %{subscriber: sub} = socket.assigns

    PubSub.broadcast(
      sub.pubsub,
      "publishers:#{sub.publisher_id}",
      {:live_ex_webrtc, :keyframe_req}
    )
  end
end
